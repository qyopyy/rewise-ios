-- 1. A repeated request with the same Idempotency-Key that arrives while the first is still
--    running now waits for it and returns its transfer, instead of failing with "quote_used".
-- 2. Sample transfers get short references dated on the day they happened.

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

  -- Another request with this key may have finished while we waited for the quote lock.
  if p_idempotency_key is not null then
    select * into v_transfer
      from public.rw_transfers
     where customer_id = p_customer and idempotency_key = p_idempotency_key;
    if found then
      return v_transfer;
    end if;
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

  update public.rw_transfers
     set short_reference = 'RW-' || to_char(created_at at time zone 'Europe/Budapest', 'YYMMDD') || '-' || right(short_reference, 5)
   where customer_id = v_customer;

  return v_token;
end;
$$;

-- Fix the dates on sample transfers created before this change.
update public.rw_transfers
   set short_reference = 'RW-' || to_char(created_at at time zone 'Europe/Budapest', 'YYMMDD') || '-' || right(short_reference, 5)
 where idempotency_key is null
   and short_reference <> 'RW-' || to_char(created_at at time zone 'Europe/Budapest', 'YYMMDD') || '-' || right(short_reference, 5);
