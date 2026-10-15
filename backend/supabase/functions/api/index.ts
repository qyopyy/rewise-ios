// Rewise API: the endpoints the iOS app calls (see BACKEND.md).
// Deployed as the `api` Edge Function with JWT verification off, because it checks
// Rewise access tokens itself. Base URL for the app: https://<project>.supabase.co/functions/v1/api
//
// Payout modes
// - No Airwallex secrets: "ledger mode". Balances and transfers live in the database and
//   payouts are simulated (they complete a few seconds after creation).
// - AIRWALLEX_CLIENT_ID + AIRWALLEX_API_KEY set: recipients become Airwallex beneficiaries and
//   transfers become Airwallex payouts (sandbox unless AIRWALLEX_ENV=production).

import { createClient } from "npm:@supabase/supabase-js@2";

type Ccy = "HUF" | "USD";
type Row = Record<string, any>;

// ---------- setup ----------

function serverKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys.default === "string") return keys.default;
  } catch (_) {
    // fall through
  }
  return "";
}

const db = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const FEE_PERCENT = { standard: 0.0045, instant: 0.0085 } as const;
const FIXED_FEE: Record<Ccy, number> = { HUF: 390, USD: 1 };
const HUF_PAYOUT_LIMIT = 10_000_000;
const QUOTE_MINUTES = 30;

// Bank holidays that move "next business day" (destination country).
const HOLIDAYS: Record<"HU" | "US", string[]> = {
  HU: ["2026-10-23", "2026-12-24", "2026-12-25", "2027-01-01", "2027-03-15", "2027-03-26", "2027-03-29", "2027-05-17", "2027-08-20", "2027-11-01", "2027-12-24"],
  US: ["2026-11-11", "2026-11-26", "2026-12-25", "2027-01-01", "2027-01-18", "2027-02-15", "2027-05-31", "2027-07-05", "2027-09-06", "2027-10-11", "2027-11-11", "2027-11-25"],
};

// ---------- small helpers ----------

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const fail = (status: number, message: string) => json(status, { message });
const iso = (value: unknown) => (value ? new Date(String(value)).toISOString() : null);
const num = (value: unknown) => (value === null || value === undefined ? null : Number(value));
const newId = (prefix: string) => `${prefix}_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
const ymd = (date: Date) => date.toISOString().slice(0, 10);
const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

function roundTo(value: number, currency: Ccy, mode: "round" | "ceil" | "floor" = "round"): number {
  const factor = currency === "HUF" ? 1 : 100;
  const scaled = value * factor;
  const whole = mode === "ceil" ? Math.ceil(scaled - 1e-9) : mode === "floor" ? Math.floor(scaled + 1e-9) : Math.round(scaled);
  return whole / factor;
}

function nextBusinessDay(country: "HU" | "US"): Date {
  const day = new Date();
  day.setUTCHours(12, 0, 0, 0);
  do {
    day.setUTCDate(day.getUTCDate() + 1);
  } while (day.getUTCDay() === 0 || day.getUTCDay() === 6 || HOLIDAYS[country].includes(ymd(day)));
  return day;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readJson(req: Request): Promise<Row> {
  try {
    const body = await req.json();
    return body && typeof body === "object" ? body : {};
  } catch (_) {
    return {};
  }
}

function validHungarianIban(iban: string): boolean {
  if (!/^HU\d{26}$/.test(iban)) return false;
  const rearranged = iban.slice(4) + iban.slice(0, 4);
  let remainder = 0;
  for (const ch of rearranged) {
    const value = /[A-Z]/.test(ch) ? String(ch.charCodeAt(0) - 55) : ch;
    for (const digit of value) remainder = (remainder * 10 + Number(digit)) % 97;
  }
  return remainder === 1;
}

function validRoutingNumber(routing: string): boolean {
  if (!/^\d{9}$/.test(routing)) return false;
  const d = [...routing].map(Number);
  return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 === 0;
}

// ---------- auth ----------

async function customerFor(req: Request): Promise<string | null> {
  const match = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(\S+)$/i);
  if (!match) return null;
  const hash = await sha256Hex(match[1]);
  const { data, error } = await db.from("rw_api_tokens").select("customer_id").eq("token_hash", hash).maybeSingle();
  if (error || !data) return null;
  await db.from("rw_api_tokens").update({ last_used_at: new Date().toISOString() }).eq("token_hash", hash);
  return data.customer_id as string;
}

// ---------- FX rates (ECB reference rates via Frankfurter, cached for an hour) ----------

type RateCache = { mid: number; previous_close: number | null; rate_date: string | null; history: { date: string; rate: number }[]; updated_at: string };

function asCache(row: Row): RateCache {
  return {
    mid: Number(row.mid),
    previous_close: num(row.previous_close),
    rate_date: row.rate_date ?? null,
    history: Array.isArray(row.history) ? row.history : [],
    updated_at: String(row.updated_at),
  };
}

// Daily USD→HUF reference rates between two dates, oldest first.
async function fetchHistory(from: string, to: string): Promise<{ date: string; rate: number }[]> {
  const get = async (url: string) => {
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`rate source returned ${res.status}`);
    return await res.json();
  };
  let points: { date: string; rate: number }[] = [];
  try {
    const rows = await get(`https://api.frankfurter.dev/v2/rates?from=${from}&to=${to}&base=usd&quotes=huf`);
    if (Array.isArray(rows)) {
      points = rows
        .filter((r) => String(r.quote).toUpperCase() === "HUF")
        .map((r) => ({ date: String(r.date), rate: Number(r.rate) }));
    }
  } catch (_) {
    // try the older endpoint below
  }
  if (points.length < 2) {
    const body = await get(`https://api.frankfurter.dev/v1/${from}..${to}?base=USD&symbols=HUF`);
    points = Object.entries(body?.rates ?? {}).map(([date, rates]) => ({ date, rate: Number((rates as Row).HUF) }));
  }
  return points.filter((p) => p.rate > 0).sort((a, b) => a.date.localeCompare(b.date));
}

async function usdHuf(): Promise<RateCache> {
  const { data: cached } = await db.from("rw_fx_rates").select("*").eq("pair", "USD-HUF").maybeSingle();
  if (cached && Date.now() - new Date(cached.updated_at).getTime() < 60 * 60 * 1000) return asCache(cached);
  try {
    const history = await fetchHistory(ymd(new Date(Date.now() - 130 * 86_400_000)), ymd(new Date()));
    if (history.length < 2) throw new Error("rate source returned no data");
    const last = history[history.length - 1];
    const previous = history[history.length - 2];
    const fresh = {
      pair: "USD-HUF",
      mid: Math.round(last.rate * 10_000) / 10_000,
      previous_close: Math.round(previous.rate * 10_000) / 10_000,
      rate_date: last.date,
      history,
      updated_at: new Date().toISOString(),
    };
    await db.from("rw_fx_rates").upsert(fresh);
    return asCache(fresh);
  } catch (e) {
    if (cached) return asCache(cached);
    throw e;
  }
}

// ---------- Airwallex (only when its secrets are set) ----------

const airwallexEnabled = () => Boolean(Deno.env.get("AIRWALLEX_CLIENT_ID") && Deno.env.get("AIRWALLEX_API_KEY"));
const airwallexBase = () =>
  Deno.env.get("AIRWALLEX_ENV") === "production" ? "https://api.airwallex.com" : "https://api.sandbox.airwallex.com";
let airwallexToken: { value: string; expiresAt: number } | null = null;

async function airwallexAuth(): Promise<string> {
  if (airwallexToken && airwallexToken.expiresAt - 60_000 > Date.now()) return airwallexToken.value;
  const res = await fetch(`${airwallexBase()}/api/v1/authentication/login`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-client-id": Deno.env.get("AIRWALLEX_CLIENT_ID")!,
      "x-api-key": Deno.env.get("AIRWALLEX_API_KEY")!,
    },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.token) throw new Error(body.message ?? `Airwallex sign-in failed (${res.status})`);
  airwallexToken = { value: body.token, expiresAt: body.expires_at ? Date.parse(body.expires_at) : Date.now() + 25 * 60_000 };
  return airwallexToken.value;
}

async function airwallex(path: string, method = "GET", payload?: unknown): Promise<Row> {
  const token = await airwallexAuth();
  const res = await fetch(`${airwallexBase()}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.message ?? `Airwallex returned ${res.status}`);
  return body;
}

async function createBeneficiary(recipient: Row): Promise<string> {
  const bankDetails = recipient.kind === "hu_bank"
    ? { account_name: recipient.name, account_currency: "HUF", bank_country_code: "HU", iban: recipient.iban }
    : {
      account_name: recipient.name,
      account_currency: "USD",
      bank_country_code: "US",
      account_number: recipient.account_number,
      account_routing_type1: "aba",
      account_routing_value1: recipient.routing_number,
    };
  // Hungarian names put the family name first ("Kovács Anna"); US names put it last.
  const parts = String(recipient.name).trim().split(/\s+/);
  const [firstName, lastName] = parts.length < 2
    ? [parts[0], parts[0]]
    : recipient.kind === "hu_bank"
    ? [parts.slice(1).join(" "), parts[0]]
    : [parts.slice(0, -1).join(" "), parts[parts.length - 1]];
  const body = await airwallex("/api/v1/beneficiaries/create", "POST", {
    beneficiary: { entity_type: "PERSONAL", first_name: firstName, last_name: lastName, bank_details: bankDetails },
    transfer_methods: ["LOCAL"],
    nickname: recipient.name,
  });
  if (!body.id) throw new Error("Airwallex didn't return a beneficiary ID");
  return String(body.id);
}

async function createPayout(transfer: Row, requestId: string): Promise<{ id: string; status: string }> {
  const { data: recipient } = await db.from("rw_recipients").select("airwallex_beneficiary_id").eq("id", transfer.recipient_id).maybeSingle();
  if (!recipient?.airwallex_beneficiary_id) {
    throw new Error("this recipient was saved before Airwallex was connected. Add it again");
  }
  const body = await airwallex("/api/v1/transfers/create", "POST", {
    request_id: requestId,
    beneficiary_id: recipient.airwallex_beneficiary_id,
    source_currency: transfer.source_currency,
    transfer_currency: transfer.target_currency,
    transfer_amount: Number(transfer.target_amount),
    transfer_method: "LOCAL",
    reference: String(transfer.reference || transfer.short_reference).slice(0, 35),
    reason: Deno.env.get("AIRWALLEX_TRANSFER_REASON") ?? "personal_remittance",
  });
  return { id: String(body.id), status: String(body.status ?? "PROCESSING") };
}

async function refreshPayouts(customer: string): Promise<void> {
  const { data } = await db.from("rw_transfers")
    .select("id, airwallex_transfer_id")
    .eq("customer_id", customer)
    .eq("status", "processing")
    .eq("payout_mode", "airwallex")
    .not("airwallex_transfer_id", "is", null)
    .limit(10);
  for (const t of data ?? []) {
    try {
      const body = await airwallex(`/api/v1/transfers/${t.airwallex_transfer_id}`);
      const status = String(body.status ?? "").toUpperCase();
      if (["PAID", "SENT", "SUCCEEDED", "COMPLETED"].includes(status)) {
        await db.from("rw_transfers").update({ status: "completed", airwallex_status: status }).eq("id", t.id);
      } else if (["FAILED", "RETURNED", "REJECTED"].includes(status)) {
        await db.rpc("rw_fail_transfer", { p_transfer_id: t.id, p_status: "failed" });
      } else if (["CANCELLED", "CANCELED"].includes(status)) {
        await db.rpc("rw_fail_transfer", { p_transfer_id: t.id, p_status: "cancelled" });
      } else {
        await db.from("rw_transfers").update({ airwallex_status: status }).eq("id", t.id);
      }
    } catch (_) {
      // Leave it processing; the next refresh tries again.
    }
  }
}

// ---------- response shapes ----------

const quoteOut = (q: Row) => ({
  id: q.id,
  source_currency: q.source_currency,
  target_currency: q.target_currency,
  source_amount: num(q.source_amount),
  fee: num(q.fee),
  target_amount: num(q.target_amount),
  rate: num(q.rate),
  speed: q.speed,
  expires_at: iso(q.expires_at),
  estimated_delivery: iso(q.estimated_delivery),
});

const transferOut = (t: Row) => ({
  id: t.id,
  kind: t.kind,
  status: t.status,
  counterparty: t.counterparty,
  counterparty_account: t.counterparty_account ?? null,
  source_currency: t.source_currency,
  source_amount: num(t.source_amount),
  target_currency: t.target_currency,
  target_amount: num(t.target_amount),
  fee: num(t.fee) ?? 0,
  rate: num(t.rate),
  speed: t.speed ?? null,
  reference: t.reference ?? null,
  created_at: iso(t.created_at),
  estimated_delivery: iso(t.estimated_delivery),
  short_reference: t.short_reference,
});

const TRANSFER_COLUMNS =
  "id, kind, status, counterparty, counterparty_account, source_currency, source_amount, target_currency, target_amount, fee, rate, speed, reference, created_at, estimated_delivery, short_reference";

// ---------- endpoints ----------

async function listAccounts(customer: string) {
  const { data, error } = await db.from("rw_accounts")
    .select("id, currency, balance, masked_number")
    .eq("customer_id", customer)
    .order("currency", { ascending: true });
  if (error) throw error;
  return json(200, (data ?? []).map((a: Row) => ({ ...a, balance: Number(a.balance) })));
}

async function getRate() {
  const rate = await usdHuf();
  return json(200, { base: "USD", quote: "HUF", mid: rate.mid, previous_close: rate.previous_close, timestamp: iso(rate.updated_at) });
}

async function getHistory(url: URL) {
  const days = Math.min(Math.max(Number(url.searchParams.get("days") ?? "90") || 90, 2), 130);
  const rate = await usdHuf();
  const since = ymd(new Date(Date.now() - days * 86_400_000));
  const points = rate.history.filter((p) => p.date >= since);
  return json(200, points.map((p) => ({ date: new Date(`${p.date}T12:00:00Z`).toISOString(), rate: p.rate })));
}

async function createQuote(customer: string, body: Row) {
  const source = String(body.source_currency ?? "") as Ccy;
  const target = String(body.target_currency ?? "") as Ccy;
  if (!["HUF", "USD"].includes(source) || !["HUF", "USD"].includes(target) || source === target) {
    return fail(400, "Send between forint and US dollars.");
  }
  const speed = body.speed === "instant" ? "instant" : "standard";
  const { mid } = await usdHuf();
  const percent = FEE_PERCENT[speed];
  const fixed = FIXED_FEE[source];

  const price = (amount: number) => {
    const fee = roundTo(amount * percent + fixed, source);
    const converted = Math.max(0, roundTo(amount - fee, source));
    const receive = target === "USD" ? roundTo(converted / mid, "USD", "floor") : roundTo(converted * mid, "HUF", "floor");
    return { fee, receive };
  };

  // Same rule as the app's demo mode: an amount to receive wins over an amount to send.
  let send: number;
  const wanted = roundTo(Number(body.target_amount), target);
  const fromTarget = body.target_amount !== undefined && body.target_amount !== null && Number.isFinite(wanted) && wanted > 0;
  if (fromTarget) {
    const needed = target === "USD" ? wanted * mid : wanted / mid;
    send = roundTo((needed + fixed) / (1 - percent), source, "ceil");
    // Rounding can leave the recipient a cent or a forint short; add the smallest unit until it doesn't.
    for (let i = 0; i < 5 && price(send).receive < wanted; i++) send = roundTo(send + (source === "HUF" ? 1 : 0.01), source);
  } else {
    send = roundTo(Number(body.source_amount), source);
  }
  if (!Number.isFinite(send) || send <= 0) return fail(400, "Enter an amount to send.");

  const { fee, receive } = price(send);
  if (target === "HUF" && receive > HUF_PAYOUT_LIMIT) {
    return fail(400, "Forint payouts are limited to 10 000 000 Ft per transfer. Split it into smaller transfers.");
  }

  const delivery = speed === "instant"
    ? new Date(Date.now() + (target === "HUF" ? 30_000 : 5 * 60_000))
    : nextBusinessDay(target === "USD" ? "US" : "HU");
  const quote = {
    id: newId("q"),
    customer_id: customer,
    source_currency: source,
    target_currency: target,
    source_amount: send,
    fee,
    target_amount: receive,
    rate: mid,
    speed,
    expires_at: new Date(Date.now() + QUOTE_MINUTES * 60_000).toISOString(),
    estimated_delivery: delivery.toISOString(),
  };
  const { error } = await db.from("rw_quotes").insert(quote);
  if (error) throw error;
  return json(200, quoteOut(quote));
}

async function listRecipients(customer: string) {
  const { data, error } = await db.from("rw_recipients")
    .select("id, name, kind, masked_account")
    .eq("customer_id", customer)
    .order("created_at", { ascending: false })
    .order("name", { ascending: true });
  if (error) throw error;
  return json(200, data ?? []);
}

async function createRecipient(customer: string, body: Row) {
  const name = String(body.name ?? "").trim();
  if (name.length < 2 || name.length > 120) return fail(400, "Enter the recipient's full name.");
  const record: Row = { id: newId("rcp"), customer_id: customer, name, kind: body.kind };
  if (body.kind === "hu_bank") {
    const iban = String(body.iban ?? "").replace(/\s+/g, "").toUpperCase();
    if (!validHungarianIban(iban)) return fail(400, "Check the IBAN. A Hungarian IBAN is HU followed by 26 digits.");
    record.iban = iban;
    record.masked_account = `${iban.slice(0, 4)} •••• •••• ${iban.slice(-4)}`;
  } else if (body.kind === "us_bank") {
    const routing = String(body.routing_number ?? "").trim();
    const account = String(body.account_number ?? "").trim();
    const type = body.account_type === "savings" ? "savings" : "checking";
    if (!validRoutingNumber(routing)) return fail(400, "Check the routing number. It has 9 digits.");
    if (!/^\d{4,17}$/.test(account)) return fail(400, "Check the account number. It has 4 to 17 digits.");
    record.routing_number = routing;
    record.account_number = account;
    record.account_type = type;
    record.masked_account = `${type === "savings" ? "Savings" : "Checking"} •••• ${account.slice(-4)}`;
  } else {
    return fail(400, "Pick a US or Hungarian bank account.");
  }
  if (airwallexEnabled()) {
    try {
      record.airwallex_beneficiary_id = await createBeneficiary(record);
    } catch (e) {
      return fail(400, `Airwallex didn't accept this account: ${errorText(e)}`);
    }
  }
  const { error } = await db.from("rw_recipients").insert(record);
  if (error) throw error;
  return json(201, { id: record.id, name, kind: record.kind, masked_account: record.masked_account });
}

async function listTransfers(customer: string) {
  await db.rpc("rw_settle_simulated", { p_customer: customer });
  if (airwallexEnabled()) await refreshPayouts(customer);
  const { data, error } = await db.from("rw_transfers")
    .select(TRANSFER_COLUMNS)
    .eq("customer_id", customer)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) throw error;
  return json(200, (data ?? []).map(transferOut));
}

function transferError(message: string) {
  if (message.includes("quote_expired")) return fail(409, "The locked rate expired. Get a new rate and try again.");
  if (message.includes("quote_used")) return fail(409, "This rate was already used. Get a new rate.");
  if (message.includes("quote_not_found")) return fail(404, "That rate quote doesn't exist. Get a new rate.");
  if (message.includes("recipient_not_found")) return fail(404, "Pick a recipient.");
  if (message.includes("recipient_currency_mismatch")) return fail(400, "This recipient can't receive that currency.");
  if (message.includes("insufficient_balance")) return fail(422, "Your balance is too low for this transfer.");
  if (message.includes("below_minimum")) return fail(400, "The minimum transfer is 5 000 Ft or $10.00.");
  if (message.includes("account_not_found")) return fail(400, "There's no account to send from.");
  return null;
}

async function createTransfer(customer: string, req: Request, body: Row) {
  const key = String(req.headers.get("idempotency-key") ?? body.idempotency_key ?? "").trim() || crypto.randomUUID();
  const mode = airwallexEnabled() ? "airwallex" : "simulated";
  const create = () =>
    db.rpc("rw_create_transfer", {
      p_customer: customer,
      p_quote_id: String(body.quote_id ?? ""),
      p_recipient_id: String(body.recipient_id ?? ""),
      p_reference: typeof body.reference === "string" ? body.reference.slice(0, 140) : null,
      p_idempotency_key: key,
      p_payout_mode: mode,
    });
  let { data, error } = await create();
  // Two taps at once with the same key: the second one returns the transfer the first one made.
  if (error?.code === "23505") ({ data, error } = await create());
  if (error) {
    const mapped = transferError(String(error.message ?? ""));
    if (mapped) return mapped;
    throw error;
  }
  let transfer = data as Row;
  if (transfer.payout_mode === "airwallex" && !transfer.airwallex_transfer_id && transfer.status === "processing") {
    try {
      const payout = await createPayout(transfer, key);
      await db.from("rw_transfers").update({ airwallex_transfer_id: payout.id, airwallex_status: payout.status }).eq("id", transfer.id);
      transfer = { ...transfer, airwallex_transfer_id: payout.id };
    } catch (e) {
      await db.rpc("rw_fail_transfer", { p_transfer_id: transfer.id, p_status: "failed" });
      return fail(400, `Airwallex didn't accept the payout, so the money went back to your account: ${errorText(e)}`);
    }
  }
  return json(201, transferOut(transfer));
}

// ---------- router ----------

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/+/, "").replace(/^api\/?/, "").replace(/\/+$/, "");
  try {
    if (req.method === "GET" && path === "health") {
      return json(200, { ok: true, payouts: airwallexEnabled() ? "airwallex" : "simulated" });
    }
    const customer = await customerFor(req);
    if (!customer) return fail(401, "Your access token is missing or no longer valid.");

    if (req.method === "GET" && path === "v1/accounts") return await listAccounts(customer);
    if (req.method === "GET" && path === "v1/rates/USD-HUF") return await getRate();
    if (req.method === "GET" && path === "v1/rates/USD-HUF/history") return await getHistory(url);
    if (req.method === "POST" && path === "v1/quotes") return await createQuote(customer, await readJson(req));
    if (req.method === "GET" && path === "v1/recipients") return await listRecipients(customer);
    if (req.method === "POST" && path === "v1/recipients") return await createRecipient(customer, await readJson(req));
    if (req.method === "GET" && path === "v1/transfers") return await listTransfers(customer);
    if (req.method === "POST" && path === "v1/transfers") return await createTransfer(customer, req, await readJson(req));
    return fail(404, "There's no such endpoint.");
  } catch (e) {
    console.error(e);
    return fail(500, "Something went wrong on the Rewise server. Try again.");
  }
});
