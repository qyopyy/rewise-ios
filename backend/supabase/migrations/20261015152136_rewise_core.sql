-- Rewise backend: customers, access tokens, accounts, recipients, quotes, transfers and an FX cache.
-- Only the `api` Edge Function (service role) reads or writes these tables.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.rw_customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.rw_api_tokens (
  token_hash text primary key,
  customer_id uuid not null references public.rw_customers(id) on delete cascade,
  label text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists rw_api_tokens_customer_idx on public.rw_api_tokens (customer_id);

create table if not exists public.rw_accounts (
  id text primary key,
  customer_id uuid not null references public.rw_customers(id) on delete cascade,
  currency text not null check (currency in ('HUF', 'USD')),
  balance numeric(20, 2) not null default 0 check (balance >= 0),
  masked_number text not null,
  created_at timestamptz not null default now(),
  unique (customer_id, currency)
);

create table if not exists public.rw_recipients (
  id text primary key,
  customer_id uuid not null references public.rw_customers(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  kind text not null check (kind in ('us_bank', 'hu_bank')),
  masked_account text not null,
  iban text,
  routing_number text,
  account_number text,
  account_type text,
  airwallex_beneficiary_id text,
  created_at timestamptz not null default now()
);
create index if not exists rw_recipients_customer_idx on public.rw_recipients (customer_id, created_at desc);

create table if not exists public.rw_quotes (
  id text primary key,
  customer_id uuid not null references public.rw_customers(id) on delete cascade,
  source_currency text not null check (source_currency in ('HUF', 'USD')),
  target_currency text not null check (target_currency in ('HUF', 'USD')),
  source_amount numeric(20, 2) not null check (source_amount > 0),
  fee numeric(20, 2) not null,
  target_amount numeric(20, 2) not null,
  rate numeric(14, 4) not null,
  speed text not null check (speed in ('standard', 'instant')),
  expires_at timestamptz not null,
  estimated_delivery timestamptz,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists rw_quotes_customer_idx on public.rw_quotes (customer_id, created_at desc);

create table if not exists public.rw_transfers (
  id text primary key,
  customer_id uuid not null references public.rw_customers(id) on delete cascade,
  kind text not null check (kind in ('outgoing', 'incoming')),
  status text not null check (status in ('processing', 'completed', 'failed', 'cancelled')),
  counterparty text not null,
  counterparty_account text,
  source_currency text not null,
  source_amount numeric(20, 2) not null,
  target_currency text not null,
  target_amount numeric(20, 2) not null,
  fee numeric(20, 2) not null default 0,
  rate numeric(14, 4),
  speed text,
  reference text,
  estimated_delivery timestamptz,
  short_reference text not null,
  quote_id text references public.rw_quotes(id),
  recipient_id text references public.rw_recipients(id) on delete set null,
  idempotency_key text,
  payout_mode text not null default 'simulated' check (payout_mode in ('simulated', 'airwallex')),
  airwallex_transfer_id text,
  airwallex_status text,
  created_at timestamptz not null default now(),
  unique (customer_id, idempotency_key)
);
create index if not exists rw_transfers_customer_idx on public.rw_transfers (customer_id, created_at desc);
create index if not exists rw_transfers_quote_idx on public.rw_transfers (quote_id);
create index if not exists rw_transfers_recipient_idx on public.rw_transfers (recipient_id);

create table if not exists public.rw_fx_rates (
  pair text primary key,
  mid numeric(14, 4) not null,
  previous_close numeric(14, 4),
  rate_date date,
  history jsonb,
  updated_at timestamptz not null default now()
);

-- Row level security on, with no policies: the public API keys can't touch anything.
alter table public.rw_customers enable row level security;
alter table public.rw_api_tokens enable row level security;
alter table public.rw_accounts enable row level security;
alter table public.rw_recipients enable row level security;
alter table public.rw_quotes enable row level security;
alter table public.rw_transfers enable row level security;
alter table public.rw_fx_rates enable row level security;

revoke all on public.rw_customers, public.rw_api_tokens, public.rw_accounts, public.rw_recipients,
  public.rw_quotes, public.rw_transfers, public.rw_fx_rates from anon, authenticated;

-- Helpers ---------------------------------------------------------------

create or replace function public.rw_new_id(prefix text)
returns text
language sql
volatile
set search_path = ''
as $$
  select prefix || '_' || encode(extensions.gen_random_bytes(8), 'hex');
$$;

create or replace function public.rw_short_ref()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'RW-' || to_char(now() at time zone 'Europe/Budapest', 'YYMMDD') || '-'
    || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 5));
$$;

-- Creates an outgoing transfer from a quote in one transaction:
-- checks the quote, recipient and balance, debits the account and marks the quote used.
create or replace function public.rw_create_transfer(
  p_customer uuid,
  p_quote_id text,
  p_recipient_id text,
  p_reference text,
  p_idempotency_key text,
  p_payout_mode text default 'simulated'
)
returns public.rw_transfers
language plpgsql
set search_path = ''
as $$
declare
  v_transfer public.rw_transfers;
  v_quote public.rw_quotes;
  v_recipient public.rw_recipients;
  v_account public.rw_accounts;
begin
  if p_idempotency_key is not null then
    select * into v_transfer
      from public.rw_transfers
     where customer_id = p_customer and idempotency_key = p_idempotency_key;
    if found then
      return v_transfer;
    end if;
  end if;

  select * into v_quote
    from public.rw_quotes
   where id = p_quote_id and customer_id = p_customer
     for update;
  if not found then
    raise exception 'quote_not_found';
  end if;
  if v_quote.used_at is not null then
    raise exception 'quote_used';
  end if;
  if v_quote.expires_at < now() then
    raise exception 'quote_expired';
  end if;
  if v_quote.source_amount < (case v_quote.source_currency when 'HUF' then 5000 else 10 end) then
    raise exception 'below_minimum';
  end if;

  select * into v_recipient
    from public.rw_recipients
   where id = p_recipient_id and customer_id = p_customer;
  if not found then
    raise exception 'recipient_not_found';
  end if;
  if (v_recipient.kind = 'us_bank' and v_quote.target_currency <> 'USD')
     or (v_recipient.kind = 'hu_bank' and v_quote.target_currency <> 'HUF') then
    raise exception 'recipient_currency_mismatch';
  end if;

  select * into v_account
    from public.rw_accounts
   where customer_id = p_customer and currency = v_quote.source_currency
     for update;
  if not found then
    raise exception 'account_not_found';
  end if;
  if v_account.balance < v_quote.source_amount then
    raise exception 'insufficient_balance';
  end if;

  update public.rw_accounts set balance = balance - v_quote.source_amount where id = v_account.id;
  update public.rw_quotes set used_at = now() where id = v_quote.id;

  insert into public.rw_transfers (
    id, customer_id, kind, status, counterparty, counterparty_account,
    source_currency, source_amount, target_currency, target_amount, fee, rate, speed,
    reference, estimated_delivery, short_reference, quote_id, recipient_id,
    idempotency_key, payout_mode
  ) values (
    public.rw_new_id('tr'), p_customer, 'outgoing', 'processing', v_recipient.name, v_recipient.masked_account,
    v_quote.source_currency, v_quote.source_amount, v_quote.target_currency, v_quote.target_amount,
    v_quote.fee, v_quote.rate, v_quote.speed,
    nullif(btrim(coalesce(p_reference, '')), ''), v_quote.estimated_delivery, public.rw_short_ref(),
    v_quote.id, v_recipient.id, p_idempotency_key, coalesce(p_payout_mode, 'simulated')
  )
  returning * into v_transfer;

  return v_transfer;
end;
$$;

-- Marks a processing transfer failed or cancelled and returns the money to the account.
create or replace function public.rw_fail_transfer(p_transfer_id text, p_status text default 'failed')
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_transfer public.rw_transfers;
begin
  select * into v_transfer from public.rw_transfers where id = p_transfer_id for update;
  if not found or v_transfer.status <> 'processing' then
    return;
  end if;
  update public.rw_transfers set status = p_status where id = p_transfer_id;
  update public.rw_accounts
     set balance = balance + v_transfer.source_amount
   where customer_id = v_transfer.customer_id and currency = v_transfer.source_currency;
end;
$$;

-- Without Airwallex keys, payouts are simulated and finish a few seconds after they're created.
create or replace function public.rw_settle_simulated(p_customer uuid)
returns integer
language sql
set search_path = ''
as $$
  with done as (
    update public.rw_transfers
       set status = 'completed'
     where customer_id = p_customer
       and status = 'processing'
       and payout_mode = 'simulated'
       and created_at < now() - case when speed = 'instant' then interval '5 seconds' else interval '9 seconds' end
    returning 1
  )
  select count(*)::integer from done;
$$;

-- Creates a customer with sample balances, recipients and history. Returns the access token once;
-- only its SHA-256 hash is stored.
create or replace function public.rw_create_demo_customer(p_name text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_customer uuid;
  v_token text := 'rw_' || encode(extensions.gen_random_bytes(24), 'hex');
  v_now timestamptz := now();
begin
  insert into public.rw_customers (name) values (p_name) returning id into v_customer;
  insert into public.rw_api_tokens (token_hash, customer_id, label)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_customer, 'iOS app');

  insert into public.rw_accounts (id, customer_id, currency, balance, masked_number) values
    (public.rw_new_id('acc'), v_customer, 'HUF', 1284500, 'HU•• •••• 2048'),
    (public.rw_new_id('acc'), v_customer, 'USD', 8420.37, 'ACH •••• 6630');

  insert into public.rw_recipients (id, customer_id, name, kind, masked_account) values
    (public.rw_new_id('rcp'), v_customer, 'Emily Carter', 'us_bank', 'Checking •••• 4821'),
    (public.rw_new_id('rcp'), v_customer, 'Daniel Brooks', 'us_bank', 'Savings •••• 7733'),
    (public.rw_new_id('rcp'), v_customer, 'Kovács Anna', 'hu_bank', 'HU42 •••• •••• 4417'),
    (public.rw_new_id('rcp'), v_customer, 'Tóth Bence', 'hu_bank', 'HU86 •••• •••• 9012');

  insert into public.rw_transfers (
    id, customer_id, kind, status, counterparty, counterparty_account, source_currency, source_amount,
    target_currency, target_amount, fee, rate, speed, reference, short_reference, created_at
  ) values
    (public.rw_new_id('tr'), v_customer, 'outgoing', 'completed', 'Emily Carter', 'Checking •••• 4821',
     'HUF', 250000, 'USD', 765.95, 1515, 324.41, 'standard', 'October studio rent', public.rw_short_ref(), v_now - interval '2 hours 18 minutes'),
    (public.rw_new_id('tr'), v_customer, 'incoming', 'completed', 'Lakeview Media LLC', 'ACH credit',
     'USD', 3200, 'USD', 3200, 0, null, null, 'Invoice 2026-041', public.rw_short_ref(), v_now - interval '27 hours'),
    (public.rw_new_id('tr'), v_customer, 'outgoing', 'completed', 'Kovács Anna', 'HU42 •••• •••• 4417',
     'USD', 400, 'HUF', 128926, 4.40, 325.90, 'instant', 'Szülinapi ajándék', public.rw_short_ref(), v_now - interval '73 hours'),
    (public.rw_new_id('tr'), v_customer, 'incoming', 'completed', 'Account top-up', 'From your Hungarian bank',
     'HUF', 500000, 'HUF', 500000, 0, null, null, null, public.rw_short_ref(), v_now - interval '146 hours'),
    (public.rw_new_id('tr'), v_customer, 'outgoing', 'completed', 'Tóth Bence', 'HU86 •••• •••• 9012',
     'USD', 1150, 'HUF', 371146, 6.18, 324.48, 'standard', 'Albérlet október', public.rw_short_ref(), v_now - interval '220 hours');

  return v_token;
end;
$$;

-- Only the service role (the Edge Function) may call these.
revoke execute on function public.rw_new_id(text) from public, anon, authenticated;
revoke execute on function public.rw_short_ref() from public, anon, authenticated;
revoke execute on function public.rw_create_transfer(uuid, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.rw_fail_transfer(text, text) from public, anon, authenticated;
revoke execute on function public.rw_settle_simulated(uuid) from public, anon, authenticated;
revoke execute on function public.rw_create_demo_customer(text) from public, anon, authenticated;

grant execute on function public.rw_new_id(text) to service_role;
grant execute on function public.rw_short_ref() to service_role;
grant execute on function public.rw_create_transfer(uuid, text, text, text, text, text) to service_role;
grant execute on function public.rw_fail_transfer(text, text) to service_role;
grant execute on function public.rw_settle_simulated(uuid) to service_role;
grant execute on function public.rw_create_demo_customer(text) to service_role;
