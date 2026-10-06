// supabase/functions/trial-emails/index.ts
//
// Trial follow-up emails (migration 139): email 2 (the 24-hour reminder) and the
// attended (3A 4A 5A 6A) and no-show (3B 4B 5B) branches, adult and kids streams.
// Email 1 is sent by trial-booking at booking time, from the same template
// module (../_shared/trial_emails.ts). Nothing schedules this function: it runs
// when someone calls it with the shared secret (hourly, once pg_cron is set up).
//
//   POST { send?: false|true, limit?: n, now?: ISO }    (now: dry run only)
//   POST { test_to: "<one address>" }   TEST SEND: all 9 codes x both streams to
//        that address, subjects "[TEST] …". Fixture people; the real Neutral Bay
//        (adult) and Camperdown (kids) units from public.units. Writes nothing and
//        ignores the daily cap. Email 1's health check link is a placeholder.
//   header x-engagement-secret: <ENGAGEMENT_SECRET>
//
// WHAT IS DUE comes from public.trial_email_candidates(now), which applies every
// rule: timing (Sydney), the 2-day lateness limit, the current session only,
// converted / status / opt-out stops, and sent-or-skipped-already.
// One more rule here: when a lead has TWO emails due at once (only after the
// function was down for a while, e.g. 3B and 4B), only the later one goes; the
// earlier is logged 'skipped' ("superseded by 4B") so it never goes after it.
//
// send:false (DEFAULT) — a dry run. Writes NOTHING. Returns the counts, the due
//   list, and rendered samples of every code for both streams.
// send:true — for each due email: CLAIM a row in email_sends (kind 'trial',
//   period_key '<session>:<code>', status 'failed' / error 'sending'; the unique
//   index email_sends_trial_once means only one run can hold it), send through
//   Resend, then mark it 'sent' or 'failed'. A failed row is retried on the next
//   run while the email is still inside its 2-day window.
//
// DAILY CAP, shared with the monthly update: EMAIL_DAILY_CAP (default 90) is a
// budget for the Sydney day. This function counts every email already sent today
// by ANY kind (email_sends rows with sent_at since Sydney midnight; a monthly
// email to one address is one email however many students it lists) and sends at
// most what is left (a smaller `limit` wins). Whatever it doesn't send stays due
// and goes on the next hourly run, unless it passes the 2-day limit.
//
// Secrets: ENGAGEMENT_SECRET, EMAIL_UNSUB_SECRET (required to send),
// RESEND_API_KEY, EMAIL_DAILY_CAP (optional). Auto: SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY. RESEND_API_URL is a TEST seam only; leave it unset.
// Deploy with --no-verify-jwt.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type Code, type Stream, CODES, classLabel, fmt12, fmtDayDate, renderTrialEmail,
  trialUnsubUrl, TRIAL_FROM, TRIAL_REPLY_TO,
} from "../_shared/trial_emails.ts";
import { parseTestTo, sleep, TEST_SEND_GAP_MS, TEST_SUBJECT_PREFIX } from "../_shared/test_to.ts";
import { unitAddressLine } from "../_shared/unit_address.ts";

const SYDNEY_TZ = "Australia/Sydney";
const DEFAULT_DAILY_CAP = 90;
const PAGE = 1000; // PostgREST row cap: everything below is paginated

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Constant-time string compare (secret header).
function safeEqual(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Midnight today in Sydney, as an instant.
function sydneyMidnight(now: Date): Date {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: SYDNEY_TZ, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  }).formatToParts(now).map((p) => [p.type, p.value]));
  const wallAsUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  const offset = wallAsUtc - Math.floor(now.getTime() / 1000) * 1000;
  return new Date(Date.UTC(+parts.year, +parts.month - 1, +parts.day) - offset);
}

async function sendViaResend(to: string, msg: { subject: string; html: string; text: string }):
  Promise<{ ok: boolean; error?: string }> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return { ok: false, error: "RESEND_API_KEY not set" };
  const url = Deno.env.get("RESEND_API_URL") || "https://api.resend.com/emails";
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ from: TRIAL_FROM, to: [to], reply_to: TRIAL_REPLY_TO, subject: msg.subject, html: msg.html, text: msg.text }),
    });
    if (!r.ok) {
      const body = await r.text().catch(() => "<no body>");
      return { ok: false, error: `HTTP ${r.status}: ${body.slice(0, 300)}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// deno-lint-ignore no-explicit-any
async function fetchAllPages<T>(make: (from: number, to: number) => any): Promise<T[]> {
  const all: T[] = [];
  for (let page = 0; page < 50; page++) {
    const from = page * PAGE;
    const { data, error } = await make(from, from + PAGE - 1);
    if (error) throw new Error(error.message || String(error));
    const rows = (data || []) as T[];
    all.push(...rows);
    if (rows.length < PAGE) break;
  }
  return all;
}

type Cand = {
  booking_id: string; session_key: string; session_id: string | null; stream: Stream; code: Code;
  due_at: string; period_key: string; recipient: string; first_name: string | null;
  child_first_name: string | null; unit_name: string | null; unit_legacy_id: string | null;
  unit_address: string | null; unit_city: string | null; unit_phone: string | null;
  class_type: string | null; class_audience: string | null; class_date: string; class_time: string;
  attempt_status: string | null;
};

// Made-up lead for samples and test sends. Never a real person.
function fixtureFor(stream: Stream, recipient: string): Cand {
  return {
    booking_id: "sample", session_key: "sample", session_id: null, stream, code: "1", due_at: new Date().toISOString(),
    period_key: "sample:1", recipient, first_name: "Sam", child_first_name: stream === "kids" ? "Mia" : null,
    unit_name: "Neutral Bay", unit_legacy_id: "nb", unit_address: "1 Example St", unit_city: "Neutral Bay",
    unit_phone: "0400 000 000", class_type: stream === "kids" ? "jun" : "beg", class_audience: stream === "kids" ? "Kids" : "Adults",
    class_date: "2026-10-15", class_time: "18:00", attempt_status: null,
  };
}

async function render(c: Cand, code: Code = c.code, stream: Stream = c.stream) {
  return renderTrialEmail(code, stream, {
    firstName: c.first_name || "",
    childFirstName: c.child_first_name || "",
    location: c.unit_name || "",
    className: c.class_type ? classLabel(c.class_type, c.class_audience || "") : "Trial class",
    trialDate: fmtDayDate(c.class_date),
    trialTime: fmt12(c.class_time),
    addressLine: unitAddressLine(c.unit_address),   // as stored; city not appended
    unitLegacyId: c.unit_legacy_id,
    unitPhone: c.unit_phone,
    waiverLink: code === "1" ? "https://mybjj-app.com/waiver.html?t=SAMPLE" : null, // samples only
    unsubscribeUrl: await trialUnsubUrl(Deno.env.get("EMAIL_UNSUB_SECRET"), c.recipient),
  });
}

Deno.serve(async (req) => {
  // 1. Shared secret. Unset secret = nobody gets in (fail closed).
  const expected = Deno.env.get("ENGAGEMENT_SECRET") || "";
  const given = req.headers.get("x-engagement-secret") || "";
  if (!expected || !safeEqual(given, expected)) return json({ error: "unauthorized" }, 401);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { body = {}; }   // an empty body is a dry run

  // TEST SEND: every code, both streams, to ONE address. Subjects prefixed
  // "[TEST] ". People are fixtures; the ACADEMY is real, read from public.units:
  // Neutral Bay for the adult stream, Camperdown for the kids stream (name,
  // address, phone, booking link). Writes nothing; no daily cap.
  if (body.test_to !== undefined) {
    const to = parseTestTo(body.test_to);
    if (!to) return json({ error: "test_to must be one valid email address" }, 400);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: unitRows, error: unitErr } = await sb.from("units").select("name, legacy_id, address, phone");
    if (unitErr) return json({ error: "read failed", detail: unitErr.message }, 500);
    type UnitRow = { name: string | null; legacy_id: string | null; address: string | null; phone: string | null };
    const unitNamed = (n: string) =>
      ((unitRows || []) as UnitRow[]).find((u) => String(u.name || "").trim().toLowerCase() === n.toLowerCase());
    const TEST_UNITS: Record<Stream, string> = { adult: "Neutral Bay", kids: "Camperdown" };
    const units: Partial<Record<Stream, UnitRow>> = {};
    for (const st of ["adult", "kids"] as Stream[]) {
      const u = unitNamed(TEST_UNITS[st]);
      if (!u) return json({ error: `unit "${TEST_UNITS[st]}" not found in public.units` }, 500);
      units[st] = u;
    }
    const results = [];
    for (const stream of ["adult", "kids"] as Stream[]) {
      const u = units[stream]!;
      const lead: Cand = {
        ...fixtureFor(stream, to),
        unit_name: String(u.name || "").trim(), unit_legacy_id: u.legacy_id ? String(u.legacy_id).toLowerCase() : null,
        unit_address: u.address, unit_city: null, unit_phone: u.phone ? String(u.phone).trim() || null : null,
      };
      for (const code of CODES) {
        if (results.length) await sleep(TEST_SEND_GAP_MS);
        const msg = await render(lead, code, stream);
        const subject = TEST_SUBJECT_PREFIX + msg.subject;
        const r = await sendViaResend(to, { ...msg, subject });
        results.push({ stream, code, subject, ok: r.ok, ...(r.ok ? {} : { error: r.error }) });
      }
    }
    return json({
      mode: "test", to, wrote: "nothing",
      academies: Object.fromEntries((["adult", "kids"] as Stream[]).map((st) => [st, {
        name: units[st]!.name, address_line: unitAddressLine(units[st]!.address), phone: units[st]!.phone }])),
      sent: results.filter((x) => x.ok).length, failed: results.filter((x) => !x.ok).length,
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: no unsubscribe link in the test emails"],
      results,
    }, 200);
  }

  const send = body.send === true;   // anything else is a dry run
  let now = new Date();
  if (body.now != null) {
    // A dry run may ask "what would be due at <time>?". A send always uses the real clock.
    if (send) return json({ error: "now is for dry runs only" }, 400);
    const t = new Date(String(body.now));
    if (isNaN(t.getTime())) return json({ error: "now must be an ISO timestamp" }, 400);
    now = t;
  }
  const envCap = Math.max(0, parseInt(Deno.env.get("EMAIL_DAILY_CAP") || "", 10) || DEFAULT_DAILY_CAP);
  const reqLimit = body.limit == null ? null : parseInt(String(body.limit), 10);
  if (reqLimit != null && (!Number.isFinite(reqLimit) || reqLimit < 0)) return json({ error: "limit must be a positive number" }, 400);
  if (send && !Deno.env.get("EMAIL_UNSUB_SECRET")) {
    return json({ error: "EMAIL_UNSUB_SECRET not set: refusing to send without an unsubscribe link" }, 500);
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let cands: Cand[];
  let sentToday: { recipient_email: string; sent_at: string }[];
  const midnight = sydneyMidnight(now);
  try {
    cands = await fetchAllPages<Cand>((a, b) =>
      supabase.rpc("trial_email_candidates", { p_now: now.toISOString() }).range(a, b));
    sentToday = await fetchAllPages<{ recipient_email: string; sent_at: string }>((a, b) =>
      supabase.from("email_sends").select("recipient_email, sent_at")
        .eq("status", "sent").gte("sent_at", midnight.toISOString()).lte("sent_at", now.toISOString())
        .order("sent_at", { ascending: true }).order("id", { ascending: true }).range(a, b));
  } catch (e) {
    return json({ error: "read failed", detail: e instanceof Error ? e.message : String(e) }, 500);
  }

  // Emails already sent today, all kinds: one per (address, sent_at). A monthly
  // email writes one row per student it covers, all with the same sent_at.
  const emailsSentToday = new Set(sentToday.map((r) => String(r.recipient_email).toLowerCase() + "|" + new Date(r.sent_at).getTime())).size;
  const budget = Math.max(0, Math.min(reqLimit == null ? Infinity : reqLimit, envCap - emailsSentToday));

  // One email per session per run: the latest due code goes, earlier ones are superseded.
  const bySession = new Map<string, Cand[]>();
  for (const c of cands) {
    const k = c.session_key + "|" + c.recipient;
    (bySession.get(k) || bySession.set(k, []).get(k)!).push(c);
  }
  const toSend: Cand[] = [];
  const superseded: { cand: Cand; by: Code }[] = [];
  for (const list of bySession.values()) {
    list.sort((x, y) => new Date(x.due_at).getTime() - new Date(y.due_at).getTime());
    const last = list[list.length - 1];
    toSend.push(last);
    for (const c of list.slice(0, -1)) superseded.push({ cand: c, by: last.code });
  }
  toSend.sort((x, y) => new Date(x.due_at).getTime() - new Date(y.due_at).getTime() || x.period_key.localeCompare(y.period_key));

  const dueRow = (c: Cand, action: string) => ({
    action, code: c.code, stream: c.stream, recipient: c.recipient, period_key: c.period_key, due_at: c.due_at,
    booking_id: c.booking_id, first_name: c.first_name, child_first_name: c.child_first_name,
    academy: c.unit_name, class_date: c.class_date, class_time: c.class_time,
  });

  // ---------------- DRY RUN: write nothing ----------------
  if (!send) {
    const due = [
      ...toSend.map((c, i) => dueRow(c, i < budget ? (c.attempt_status === "failed" ? "would_retry" : "would_send") : "over_daily_cap_next_run")),
      ...superseded.map(({ cand, by }) => ({ ...dueRow(cand, "would_skip_superseded"), superseded_by: by })),
    ];
    // Samples: every code, both streams. A real due lead when there is one,
    // otherwise a made-up one (marked as such).
    const samples = [];
    for (const stream of ["adult", "kids"] as Stream[]) {
      const real = cands.find((c) => c.stream === stream);
      const base = real || fixtureFor(stream, "sample@example.invalid");
      for (const code of CODES) {
        samples.push({
          stream, code, to: base.recipient, from_real_lead: !!real,
          ...(code === "1" ? { note: "email 1 is sent by trial-booking at booking time; shown here for review (the health check link is a placeholder)" } : {}),
          ...(await render(base, code, stream)),
        });
      }
    }
    return json({
      mode: "dry_run", wrote: "nothing", now: now.toISOString(),
      daily_cap: envCap, emails_sent_today_all_kinds: emailsSentToday, budget_this_run: budget,
      counts: {
        due: cands.length,
        would_send: Math.min(budget, toSend.length),
        of_which_retries: toSend.slice(0, budget).filter((c) => c.attempt_status === "failed").length,
        over_daily_cap: Math.max(0, toSend.length - budget),
        would_skip_superseded: superseded.length,
        by_code: Object.fromEntries(CODES.slice(1).map((k) => [k, toSend.filter((c) => c.code === k).length])),
      },
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: samples have no unsubscribe link, and send:true will refuse"],
      due,
      samples,
    }, 200);
  }

  // ---------------- SEND ----------------
  // Claim: a new row, or re-take a 'failed' one. email_sends_trial_once makes the
  // claim exclusive. Returns the row id, or null when another run holds it.
  const claim = async (c: Cand, status: "failed" | "skipped", error: string): Promise<string | null> => {
    if (c.attempt_status === "failed") {
      const { data, error: e } = await supabase.from("email_sends")
        .update({ status, error, sent_at: null })
        .eq("kind", "trial").eq("period_key", c.period_key).eq("recipient_email", c.recipient).eq("status", "failed")
        .select("id");
      return !e && data && data.length ? data[0].id : null;
    }
    const { data, error: e } = await supabase.from("email_sends").insert({
      kind: "trial", period_key: c.period_key, student_id: null, recipient_email: c.recipient, status, error,
    }).select("id");
    return !e && data && data.length ? data[0].id : null;
  };

  let sent = 0, failed = 0, skipped = 0, lostClaim = 0, overCap = 0;
  const failures: unknown[] = [];
  for (const { cand, by } of superseded) {
    if (await claim(cand, "skipped", `superseded by ${by}`)) skipped++; else lostClaim++;
  }
  let attempts = 0;
  for (const c of toSend) {
    if (attempts >= budget) { overCap++; continue; }
    const id = await claim(c, "failed", "sending");
    if (!id) { lostClaim++; continue; }
    attempts++;
    const res = await sendViaResend(c.recipient, await render(c));
    await supabase.from("email_sends")
      .update(res.ok ? { status: "sent", error: null, sent_at: new Date().toISOString() } : { status: "failed", error: res.error || "send failed" })
      .eq("id", id);
    if (res.ok) sent++;
    else { failed++; failures.push({ recipient: c.recipient, period_key: c.period_key, error: res.error }); }
  }
  return json({
    mode: "send", now: now.toISOString(),
    daily_cap: envCap, emails_sent_today_before_run: emailsSentToday, budget_this_run: budget,
    emails_sent: sent, emails_failed: failed, skipped_superseded: skipped,
    over_daily_cap: overCap, claimed_by_another_run: lostClaim,
    failures,
  }, 200);
});
