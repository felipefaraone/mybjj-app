// supabase/functions/mia-emails/index.ts
//
// MIA ("missing in action") emails (migration 140): M1-M4 at 7, 14, 21 and 30
// days since a member's last class, the team note T4 to info@mybjj.com.au with
// M4, and R ("great to have you back") the day after they return. Templates:
// ../_shared/mia_emails.ts. Nothing schedules this function: it runs when
// someone calls it with the shared secret (hourly, once pg_cron is set up).
// A separate function rather than a path in trial-emails: different people,
// rules and copy; the shared pieces (layout, sender, test_to, unsubscribe link)
// are already modules both import.
//
//   POST { send?: false|true, limit?: n, now?: ISO }    (now: dry run only)
//   POST { test_to: "<one address>" }   TEST SEND: every code x both streams
//        (12 emails, T4 included) to that address, subjects "[TEST] …". Fixture
//        people; the real Neutral Bay (adult) and Camperdown (kids) units from
//        public.units. Writes nothing and ignores the daily cap.
//   header x-engagement-secret: <ENGAGEMENT_SECRET>
//
// WHAT IS DUE comes from public.mia_email_candidates(now), which applies every
// rule: eligibility (active, not on hold, has trained, not a visitor or casual
// tier, not staff), 15:00 Sydney timing, the 2-day lateness limit, the current
// absence only (a newer class stops it), R only after a sent M1, recipients and
// opt-outs, and sent-or-skipped-already. T4 rows come addressed to
// info@mybjj.com.au, with what the member actually got (sent_codes,
// member_reach) for its "Automated emails sent: …" line.
//
// send:false (DEFAULT) — a dry run. Writes NOTHING. Returns the counts, the due
//   list, and rendered samples of every code for both streams.
// send:true — for each due email: CLAIM a row in email_sends (kind 'mia',
//   period_key '<student>:<last class date>:<code>', with the student_id, status
//   'failed' / error 'sending'; 137's unique key makes the claim exclusive), send,
//   then mark it 'sent' or 'failed'. A failed row is retried on the next run while
//   the email is still inside its 2-day window.
//
// DAILY CAP, shared: EMAIL_DAILY_CAP (default 90) is a budget for the Sydney day,
// counted across every kind as trial-emails does; at most MAX_EMAILS_PER_RUN (60)
// per run; sends paced at 2 a second with 429 retries; no new send after 100 s.
// Whatever is not sent stays due for the next hourly run, inside its 2 days.
//
// Secrets: ENGAGEMENT_SECRET, EMAIL_UNSUB_SECRET (required to send),
// RESEND_API_KEY, EMAIL_DAILY_CAP (optional). Auto: SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY. RESEND_API_URL is a TEST seam only; leave it unset.
// Deploy with --no-verify-jwt.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type MiaCode, type MiaParent, type MiaSent, type MiaStream, MIA_CODES, noneReason, renderMiaEmail, TEAM_ADDRESS,
} from "../_shared/mia_emails.ts";
import { TRIAL_FROM, TRIAL_REPLY_TO } from "../_shared/trial_emails.ts";
import { parseTestTo, TEST_SUBJECT_PREFIX } from "../_shared/test_to.ts";
import { createPacedSender, MAX_EMAILS_PER_RUN, type SendResult } from "../_shared/resend_send.ts";
import { unitAddressLine } from "../_shared/unit_address.ts";
import { unsubLink } from "../_shared/unsub_link.ts";
type PacedSender = ReturnType<typeof createPacedSender>;

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
function sydneyDateStr(d: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: SYDNEY_TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

// Same from / reply_to as every member email (MyBJJ, info@mybjj.com.au).
function sendViaResend(sender: PacedSender, to: string, msg: { subject: string; html: string; text: string }): Promise<SendResult> {
  return sender.send({ from: TRIAL_FROM, to: [to], reply_to: TRIAL_REPLY_TO, subject: msg.subject, html: msg.html, text: msg.text });
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
  student_id: string; code: MiaCode; due_at: string; period_key: string; recipient: string;
  recipient_name: string | null; is_kid: boolean; first_name: string | null; last_name: string | null;
  membership_level: string | null; unit_name: string | null; unit_legacy_id: string | null;
  unit_address: string | null; unit_phone: string | null; last_class_date: string; days_absent: number;
  parents: MiaParent[] | null; sent_codes: string[] | null; member_reach: string | null; attempt_status: string | null;
};

// Made-up people for samples and test sends. Never a real person.
function fixtureFor(stream: MiaStream, code: MiaCode, recipient: string): Cand {
  const last = new Date(Date.now() - 30 * 86400000);
  return {
    student_id: "sample", code, due_at: new Date().toISOString(), period_key: "sample:" + code,
    recipient, recipient_name: stream === "kids" ? "Jo Parent" : null, is_kid: stream === "kids",
    first_name: stream === "kids" ? "Mia" : "Sam", last_name: "Sample",
    membership_level: stream === "kids" ? null : "plan_unlimited",
    unit_name: "Neutral Bay", unit_legacy_id: "nb", unit_address: "1 Example St", unit_phone: "0400 000 000",
    last_class_date: sydneyDateStr(last), days_absent: 30,
    parents: stream === "kids" && code === "T4"
      ? [{ name: "Jo Parent", email: "jo.parent@example.invalid", phone: "0400 000 001" }, { name: "Pat Parent", email: "pat.parent@example.invalid", phone: null }]
      : null,
    // T4 samples show both forms of the line: everything sent (adult), none (kid).
    sent_codes: code === "T4" ? (stream === "kids" ? [] : ["M1", "M2", "M3", "M4"]) : null,
    member_reach: code === "T4" ? (stream === "kids" ? "opted_out" : "reachable") : null,
    attempt_status: null,
  };
}

async function render(c: Cand, code: MiaCode = c.code, stream: MiaStream = c.is_kid ? "kids" : "adult",
                      automated: MiaSent | null = { codes: c.sent_codes || [], reason: noneReason(c.member_reach, false) }) {
  return renderMiaEmail(code, stream, {
    firstName: c.first_name || "",
    lastName: c.last_name,
    recipientName: c.recipient_name,
    location: c.unit_name || "",
    addressLine: unitAddressLine(c.unit_address),
    unitPhone: c.unit_phone,
    lastClassDate: c.last_class_date,
    daysAbsent: Number(c.days_absent) || 0,
    membershipLevel: c.membership_level,
    parents: c.parents,
    automated,
    unsubscribeUrl: code === "T4" ? null : await unsubLink(Deno.env.get("EMAIL_UNSUB_SECRET"), c.recipient, "mia"),
  });
}

Deno.serve(async (req) => {
  const requestStart = Date.now();
  // 1. Shared secret. Unset secret = nobody gets in (fail closed).
  const expected = Deno.env.get("ENGAGEMENT_SECRET") || "";
  const given = req.headers.get("x-engagement-secret") || "";
  if (!expected || !safeEqual(given, expected)) return json({ error: "unauthorized" }, 401);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { body = {}; }   // an empty body is a dry run

  // TEST SEND: every code, both streams, to ONE address. Fixture people; the
  // ACADEMY is real (public.units): Neutral Bay for adults, Camperdown for kids.
  if (body.test_to !== undefined) {
    const to = parseTestTo(body.test_to);
    if (!to) return json({ error: "test_to must be one valid email address" }, 400);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: unitRows, error: unitErr } = await sb.from("units").select("name, legacy_id, address, phone");
    if (unitErr) return json({ error: "read failed", detail: unitErr.message }, 500);
    type UnitRow = { name: string | null; legacy_id: string | null; address: string | null; phone: string | null };
    const unitNamed = (n: string) =>
      ((unitRows || []) as UnitRow[]).find((u) => String(u.name || "").trim().toLowerCase() === n.toLowerCase());
    const TEST_UNITS: Record<MiaStream, string> = { adult: "Neutral Bay", kids: "Camperdown" };
    const units: Partial<Record<MiaStream, UnitRow>> = {};
    for (const st of ["adult", "kids"] as MiaStream[]) {
      const u = unitNamed(TEST_UNITS[st]);
      if (!u) return json({ error: `unit "${TEST_UNITS[st]}" not found in public.units` }, 500);
      units[st] = u;
    }
    const results = [];
    const testSender = createPacedSender();
    for (const stream of ["adult", "kids"] as MiaStream[]) {
      const u = units[stream]!;
      for (const code of MIA_CODES) {
        const c: Cand = {
          ...fixtureFor(stream, code, to),
          unit_name: String(u.name || "").trim(), unit_legacy_id: u.legacy_id ? String(u.legacy_id).toLowerCase() : null,
          unit_address: u.address, unit_phone: u.phone ? String(u.phone).trim() || null : null,
        };
        const msg = await render(c, code, stream);
        const subject = TEST_SUBJECT_PREFIX + msg.subject;
        const r = await sendViaResend(testSender, to, { ...msg, subject });
        results.push({ stream, code, subject, ok: r.ok, ...(r.ok ? {} : { error: r.error }) });
      }
    }
    return json({
      mode: "test", to, wrote: "nothing",
      academies: Object.fromEntries((["adult", "kids"] as MiaStream[]).map((st) => [st, {
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
      supabase.rpc("mia_email_candidates", { p_now: now.toISOString() }).range(a, b));
    sentToday = await fetchAllPages<{ recipient_email: string; sent_at: string }>((a, b) =>
      supabase.from("email_sends").select("recipient_email, sent_at")
        .eq("status", "sent").gte("sent_at", midnight.toISOString()).lte("sent_at", now.toISOString())
        .order("sent_at", { ascending: true }).order("id", { ascending: true }).range(a, b));
  } catch (e) {
    return json({ error: "read failed", detail: e instanceof Error ? e.message : String(e) }, 500);
  }

  // Emails already sent today, all kinds: one per (address, sent_at).
  const emailsSentToday = new Set(sentToday.map((r) => String(r.recipient_email).toLowerCase() + "|" + new Date(r.sent_at).getTime())).size;
  // What this run may send: the daily cap's remainder, a smaller `limit`, and at
  // most MAX_EMAILS_PER_RUN so the run ends inside the 150 s request timeout.
  const budget = Math.max(0, Math.min(reqLimit == null ? Infinity : reqLimit, envCap - emailsSentToday, MAX_EMAILS_PER_RUN));
  const toSend = [...cands].sort((x, y) => new Date(x.due_at).getTime() - new Date(y.due_at).getTime() || x.period_key.localeCompare(y.period_key) || x.recipient.localeCompare(y.recipient));

  // T4's "Automated emails sent" in a dry run: what is logged, plus the M4 this run
  // would send for the same episode (M4 sorts before its T4).
  const willSend = new Set(toSend.slice(0, budget).map((c) => c.period_key));
  const dryAutomated = (t: Cand): MiaSent => {
    const m4 = t.period_key.replace(/:T4$/, ":M4");
    const codes = [...(t.sent_codes || []), ...(willSend.has(m4) ? ["M4"] : [])];
    return { codes, reason: noneReason(t.member_reach, false) };
  };

  // ---------------- DRY RUN: write nothing ----------------
  if (!send) {
    const due = toSend.map((c, i) => ({
      action: i < budget ? (c.attempt_status === "failed" ? "would_retry" : "would_send") : "over_daily_cap_next_run",
      code: c.code, stream: c.is_kid ? "kids" : "adult", recipient: c.recipient, period_key: c.period_key, due_at: c.due_at,
      student_id: c.student_id, first_name: c.first_name, academy: c.unit_name, last_class_date: c.last_class_date, days_absent: c.days_absent,
    }));
    const samples = [];
    for (const stream of ["adult", "kids"] as MiaStream[]) {
      for (const code of MIA_CODES) {
        const real = cands.find((c) => (c.is_kid ? "kids" : "adult") === stream && c.code === code);
        const base = real || fixtureFor(stream, code, code === "T4" ? TEAM_ADDRESS : "sample@example.invalid");
        samples.push({ stream, code, to: base.recipient, from_real_member: !!real, ...(await render(base, code, stream, real ? dryAutomated(real) : undefined)) });
      }
    }
    return json({
      mode: "dry_run", wrote: "nothing", now: now.toISOString(),
      daily_cap: envCap, emails_sent_today_all_kinds: emailsSentToday, max_per_run: MAX_EMAILS_PER_RUN, budget_this_run: budget,
      counts: {
        due: cands.length,
        would_send: Math.min(budget, toSend.length),
        of_which_retries: toSend.slice(0, budget).filter((c) => c.attempt_status === "failed").length,
        over_daily_cap: Math.max(0, toSend.length - budget),
        by_code: Object.fromEntries(MIA_CODES.map((k) => [k, toSend.filter((c) => c.code === k).length])),
      },
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: samples have no unsubscribe link, and send:true will refuse"],
      due,
      samples,
    }, 200);
  }

  // ---------------- SEND ----------------
  // Claim: a new row, or re-take a 'failed' one. 137's unique key (kind,
  // period_key, student_id, recipient_email) makes the claim exclusive.
  const claim = async (c: Cand): Promise<string | null> => {
    if (c.attempt_status === "failed") {
      const { data, error: e } = await supabase.from("email_sends")
        .update({ status: "failed", error: "sending", sent_at: null })
        .eq("kind", "mia").eq("period_key", c.period_key).eq("student_id", c.student_id)
        .eq("recipient_email", c.recipient).eq("status", "failed")
        .select("id");
      return !e && data && data.length ? data[0].id : null;
    }
    const { data, error: e } = await supabase.from("email_sends").insert({
      kind: "mia", period_key: c.period_key, student_id: c.student_id, recipient_email: c.recipient, status: "failed", error: "sending",
    }).select("id");
    return !e && data && data.length ? data[0].id : null;
  };

  // What the member got for this T4's episode, from email_sends right now.
  const sentThisEpisode = async (t: Cand): Promise<MiaSent> => {
    const prefix = t.period_key.replace(/T4$/, "");
    const { data } = await supabase.from("email_sends").select("period_key, status, error")
      .eq("kind", "mia").eq("student_id", t.student_id);
    const rows = ((data || []) as { period_key: string; status: string; error: string | null }[])
      .filter((r) => r.period_key.startsWith(prefix) && /^M[1-4]$/.test(r.period_key.slice(prefix.length)));
    const codes = rows.filter((r) => r.status === "sent").map((r) => r.period_key.slice(prefix.length));
    const m4Failed = rows.some((r) => r.status === "failed" && r.period_key.endsWith(":M4") && r.error !== "sending");
    return { codes, reason: noneReason(t.member_reach, m4Failed) };
  };

  let sent = 0, failed = 0, lostClaim = 0, overCap = 0, attempts = 0, deferred = 0, retries429 = 0;
  let stopReason: string | null = null;
  const failures: unknown[] = [];
  const sender = createPacedSender(requestStart);
  for (const c of toSend) {
    if (attempts >= budget) { overCap++; continue; }
    // Out of run time, or Resend said stop: leave it unclaimed; still due next run.
    if (!stopReason && !sender.canStartAnother()) stopReason = "run time budget reached";
    if (stopReason) { deferred++; continue; }
    const id = await claim(c);
    if (!id) { lostClaim++; continue; }
    attempts++;
    // T4 reads the log fresh, so an M4 sent earlier in THIS run is listed.
    let automated: MiaSent | undefined;
    if (c.code === "T4") automated = await sentThisEpisode(c);
    const res = await sendViaResend(sender, c.recipient, await render(c, c.code, c.is_kid ? "kids" : "adult", automated));
    retries429 += Math.max(0, res.attempts - 1);
    if (res.stop) stopReason = "Resend rate limit: " + (res.error || "429");
    await supabase.from("email_sends")
      .update(res.ok ? { status: "sent", error: null, sent_at: new Date().toISOString() } : { status: "failed", error: res.error || "send failed" })
      .eq("id", id);
    if (res.ok) sent++;
    else { failed++; failures.push({ recipient: c.recipient, period_key: c.period_key, error: res.error }); }
  }
  return json({
    mode: "send", now: now.toISOString(),
    daily_cap: envCap, emails_sent_today_before_run: emailsSentToday, budget_this_run: budget,
    emails_sent: sent, emails_failed: failed,
    over_daily_cap: overCap, claimed_by_another_run: lostClaim,
    max_per_run: MAX_EMAILS_PER_RUN, deferred_to_next_run: deferred, stopped: stopReason,
    retries_after_429: retries429, run_ms: sender.elapsedMs(),
    failures,
  }, 200);
});
