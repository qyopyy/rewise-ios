# Rewise backend

The iOS app never talks to Airwallex. It calls the Rewise backend, which keeps any Airwallex keys, checks the customer's access token, and keeps balances and transfers in the database.

## What's deployed

Supabase project `gctzysmrjbiqmolnopbm` (EU West). Source in `backend/supabase/`.

- **Base URL**: `https://gctzysmrjbiqmolnopbm.supabase.co/functions/v1/api`, already the app's default. `GET /health` answers without a token.
- **Edge Function** `api` (`functions/api/index.ts`). Supabase's JWT check is off for it because it checks Rewise access tokens itself.
- **Database** (`migrations/`): `rw_customers`, `rw_api_tokens` (SHA-256 hashes only, never the token), `rw_accounts`, `rw_recipients`, `rw_quotes`, `rw_transfers`, `rw_fx_rates`. Row level security is on with no policies, so the project's public keys can't read or change anything; only the function can.
- **Rates**: ECB reference rates (USD→HUF) from Frankfurter, cached for an hour, with 130 days of history for the chart.
- **Prices**: same rules as the app's demo mode. Standard 0.45%, Instant 0.85%, plus 390 Ft or $1, at the mid rate. Quotes hold for 30 minutes. Minimum 5,000 Ft or $10; forint payouts up to 10,000,000 Ft.

### Ledger mode (now)

Balances live in the database and payouts are simulated: a transfer takes the money from the balance and shows **Completed** about 10 seconds later. No real money moves.

Make a customer with sample balances, recipients and history, and get its access token (Supabase → SQL editor):

```sql
select public.rw_create_demo_customer('Name');
```

The token is shown once; only its hash is stored. Add money to a balance:

```sql
update public.rw_accounts
   set balance = balance + 100000
 where currency = 'HUF'
   and customer_id = (select id from public.rw_customers where name = 'Name');
```

### Real payouts with Airwallex

In Supabase → **Edge Functions → Secrets**, add:

| Name | Value |
| --- | --- |
| `AIRWALLEX_CLIENT_ID` | Airwallex web app → Developer → API keys |
| `AIRWALLEX_API_KEY` | same page |
| `AIRWALLEX_ENV` | `production` when you go live. Leave it out to use the sandbox. |
| `AIRWALLEX_TRANSFER_REASON` | optional payment reason, default `personal_remittance` |

The function picks them up on the next request; `GET /health` then shows `"payouts": "airwallex"`. From then on:

- New recipients are created as Airwallex beneficiaries (`POST /api/v1/beneficiaries/create`). Recipients saved before the keys were added need to be added again.
- Each transfer takes the money from the customer's Rewise balance, then creates an Airwallex payout (`POST /api/v1/transfers/create`) for the quoted amount in the recipient's currency, with `request_id` set to the app's idempotency key so retries never pay twice.
- If Airwallex refuses the payout, the transfer is marked **Failed** and the money goes back to the balance. Each time the app loads transfers, the backend checks Airwallex for status changes.
- Payouts are paid from your Airwallex wallet. Airwallex converts at its own rate, so the Rewise fee is your margin.

Try everything in the sandbox first. Forint payouts clear locally (GIRO) in 0 to 1 business days, with a 10,000,000 HUF limit per transfer; US payouts go by ACH.

### Change and redeploy

- **Function**: with the Supabase CLI, from `backend/`, run `supabase functions deploy api --project-ref gctzysmrjbiqmolnopbm` (the JWT check stays off through `supabase/config.toml`).
- **Database**: add a new file to `supabase/migrations/` and run it in the SQL editor. To use `supabase db push` instead, run `supabase link --project-ref gctzysmrjbiqmolnopbm` and `supabase migration fetch` first, because the project also has an older `create_releases_table` migration that isn't in this folder.

## API contract

- **Auth**: every request carries `Authorization: Bearer <token>`; `401` when it's missing or unknown.
- **JSON**: snake_case keys, ISO 8601 dates (`2026-10-15T14:05:00.000Z`), amounts as JSON numbers in major units (`250000` = 250 000 Ft, `765.95` = $765.95).
- **Errors**: any non-2xx with `{"message": "Text the customer can read"}`. `409` for an expired or used quote, `422` with the word "balance" for insufficient funds.

| Method | Path | Body | Returns |
| --- | --- | --- | --- |
| GET | `/health` | | `{"ok": true, "payouts": "simulated"}` (no token needed) |
| GET | `/v1/accounts` | | `[Account]` |
| GET | `/v1/rates/USD-HUF` | | `FXRate` |
| GET | `/v1/rates/USD-HUF/history?days=90` | | `[RatePoint]` |
| POST | `/v1/quotes` | `QuoteRequest` | `Quote` |
| GET | `/v1/recipients` | | `[Recipient]` (newest first) |
| POST | `/v1/recipients` | `RecipientDraft` | `Recipient` |
| GET | `/v1/transfers` | | `[Transfer]` (newest first, up to 100) |
| POST | `/v1/transfers` | `TransferRequest` + header `Idempotency-Key` | `Transfer` |

### Shapes

```json
// Account
{ "id": "acc_6188f9b8c2ad5f38", "currency": "HUF", "balance": 1284500, "masked_number": "HU•• •••• 2048" }

// FXRate: forint per 1 dollar
{ "base": "USD", "quote": "HUF", "mid": 324.8, "previous_close": 325.11, "timestamp": "2026-10-15T15:30:51.144Z" }

// RatePoint
{ "date": "2026-10-14T12:00:00.000Z", "rate": 325.11 }

// QuoteRequest: send source_amount or target_amount (target_amount wins if both are there)
{ "source_currency": "HUF", "target_currency": "USD", "source_amount": 250000, "speed": "standard" }

// Quote
{ "id": "q_8c0e3f8e411f4d45", "source_currency": "HUF", "target_currency": "USD", "source_amount": 250000,
  "fee": 1515, "target_amount": 765.04, "rate": 324.8, "speed": "standard",
  "expires_at": "2026-10-15T16:01:33.655Z", "estimated_delivery": "2026-10-16T12:00:00.000Z" }

// RecipientDraft (what the app sends)
{ "name": "Kovács Anna", "kind": "hu_bank", "iban": "HU42117730161111101800000000",
  "routing_number": "", "account_number": "", "account_type": "checking" }

// Recipient (full account numbers are never sent back)
{ "id": "rcp_8e85e40e519142cf", "name": "Kovács Anna", "kind": "hu_bank", "masked_account": "HU42 •••• •••• 0000" }

// TransferRequest
{ "quote_id": "q_8c0e3f8e411f4d45", "recipient_id": "rcp_8e85e40e519142cf", "reference": "Szülinapi ajándék", "idempotency_key": "8C1F…" }

// Transfer: status is processing | completed | failed | cancelled; kind is outgoing | incoming
{ "id": "tr_bb65d0718dccfd16", "kind": "outgoing", "status": "processing", "counterparty": "Emily Carter",
  "counterparty_account": "Checking •••• 4821", "source_currency": "HUF", "source_amount": 250000,
  "target_currency": "USD", "target_amount": 765.04, "fee": 1515, "rate": 324.8, "speed": "standard",
  "reference": "Backend test", "created_at": "2026-10-15T15:33:12.215Z",
  "estimated_delivery": "2026-10-16T12:00:00.000Z", "short_reference": "RW-261015-E404B" }
```

`kind` values: `us_bank` (needs `routing_number`, `account_number`, `account_type`) and `hu_bank` (needs `iban`). `speed` values: `standard`, `instant`.

## Before real customers

- Sending other people's money needs Airwallex's platform setup, with each customer onboarded and verified, or licenses of your own. A single business account isn't enough for that. Confirm the right product with Airwallex.
- Replace the pasted access token with real sign-in (Sign in with Apple or email codes).
- Customer balances here are a ledger in your database. With real customers they must match money you actually hold for them (Airwallex balances or a safeguarding account).
- Use Airwallex FX quotes instead of ECB reference rates, and turn Airwallex webhooks into status updates and push notifications.
