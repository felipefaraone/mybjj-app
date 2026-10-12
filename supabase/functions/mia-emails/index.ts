// supabase/functions/mia-emails/index.ts
//
// MIA ("missing in action") emails (migration 140): M1-M4 when a member has not
// trained for a while, the team note T4 to info@mybjj.com.au with M4, and R
// ("great to have you back") after they return. The SCHEDULE lives in the
// database, not in code: public.mia_codes (days per code) and public.mia_settings
// (settle delay, unit gate, lateness), migration 143. Templates:
// ../_shared/mia_emails.ts. Nothing schedules this function: it runs when
// someone calls it with the shared secret (hourly, once pg_cron is set up).
// A separate function rather than a path in trial-emails: different people,
// rules and copy; the shared pieces (layout, sender, test_to, unsubscribe link)
// are already modules both import.
//
//   POST { send?: false|true, limit?: n, now?: ISO }    (now: dry run only)
//   POST { test_to: "<one address>", test_set?: "all"|"plural" }   TEST SEND:
//        every code x both streams (12, T4 included) + the plural kids copy for
//        2+ children (5); test_set "plural" sends only those 5. Subjects "[TEST] …". Fixture
//        people; the real Neutral Bay (adult) and Camperdown (kids) units from
//        public.units. Writes nothing and ignores the daily cap.
//   header x-engagement-secret: <ENGAGEMENT_SECRET>
//
// WHAT IS DUE comes from public.mia_email_candidates(now), which applies every
// rule: eligibility (active, not on hold, has trained, not a visitor or casual
// tier, not staff), 15:00 Sydney timing after the settle delay, the unit gate,
// the lateness rule, the current absence only (a newer class stops it), R only
// after a sent M1, recipients and opt-outs, and sent-or-skipped-already.
// This function reads public.mia_codes once per run for the T4 line's days; if
// that read fails, no T4 is sent in that run (logged) and member emails go on. T4 rows come addressed to
// info@mybjj.com.au, with what the member actually got (sent_codes,
// member_reach) for its "Automated emails sent: …" line.
//
// ONE AUTOMATED EMAIL PER ADDRESS PER SYDNEY DAY (migration 144): before a member
// group is claimed, public.email_sent_today(address, now) and this run's own sends
// are checked; if the address already had one today the group is deferred (left
// unclaimed, still due). The most advanced stage goes first (highestStageFirst).
// T4 is never limited. If the check fails, no member email goes this run.
//
// ONE EMAIL PER ADDRESS AND CODE (see groupCands): a guardian of several children
// at the same stage gets one email naming them all; email_sends still gets one
// row per student, all sharing that send. The cap and budget count emails.
//
// send:false (DEFAULT) — a dry run. Writes NOTHING. Returns the counts, the due
//   EMAILS (recipient, code, children, subject, the rows each covers), and
//   rendered samples of every code for both streams plus the plural kids copy.
// send:true — for each due email: CLAIM a row in email_sends (kind 'mia',
//   period_key '<student>:<last class date>:<code>', with the student_id, status
//   'failed' / error 'sending'; 137's unique key makes the claim exclusive), send,
//   then mark it 'sent' or 'failed'. A failed row is retried on the next run while
//   the email is still due (migration 143's lateness rule).
//
// DAILY CAP, shared: EMAIL_DAILY_CAP (default 90) is a budget for the Sydney day,
// counted across every kind as trial-emails does; at most MAX_EMAILS_PER_RUN (60)
// per run; sends paced at 2 a second with 429 retries; no new send after 100 s.
// Whatever is not sent stays due for the next hourly run while it is still due.
//
// Secrets: ENGAGEMENT_SECRET, EMAIL_UNSUB_SECRET (required to send),
// RESEND_API_KEY, EMAIL_DAILY_CAP (optional). Auto: SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY. RESEND_API_URL is a TEST seam only; leave it unset.
// Deploy with --no-verify-jwt.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type MiaCode, type MiaDays, type MiaParent, type MiaSent, type MiaStream, MIA_CODES, noneReason, renderMiaEmail, TEAM_ADDRESS,
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

// The MIA schedule ({ M1: 10, M2: 14, ... }) from public.mia_codes, read once per
// run with the service role. null when it cannot be read: the caller then sends
// no T4 in that run (its "Automated emails sent" line would be wrong).
// deno-lint-ignore no-explicit-any
async function readMiaDays(sb: any): Promise<MiaDays | null> {
  const { data, error } = await sb.from("mia_codes").select("code, days");
  if (error || !Array.isArray(data) || !data.length) {
    console.error("[mia-emails] could not read public.mia_codes:", error ? error.message : "no rows");
    return null;
  }
  const out: MiaDays = {};
  for (const r of data as { code: string; days: number }[]) if (r && r.code) out[r.code] = Number(r.days);
  return out;
}

// Made-up children for the plural samples (rendered "Ava, Leo and Mia").
const FIXTURE_SIBLINGS = ["Mia", "Leo", "Ava"];

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

async function render(c: Cand, daysOf: MiaDays | null, code: MiaCode = c.code, stream: MiaStream = c.is_kid ? "kids" : "adult",
                      automated: MiaSent | null = { codes: c.sent_codes || [], reason: noneReason(c.member_reach, false) },
                      groupNames?: string[]) {
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
    daysOf,
    groupFirstNames: groupNames,
    unsubscribeUrl: code === "T4" ? null : await unsubLink(Deno.env.get("EMAIL_UNSUB_SECRET"), c.recipient, "mia"),
  });
}

// ONE EMAIL PER ADDRESS AND CODE. A guardian with three children at the same
// stage used to get three identical emails on the same day. Member rows group by
// (lowercased recipient, code, kids/adults): kids become one email naming every
// child (plural copy for 2+), adults sharing an address one email with the names
// joined. Codes are never mixed, nor kid and adult wording. T4 (the team note) is
// never grouped. email_sends keeps one row PER STUDENT (137's unique key), all
// rows of a group sharing the one send.
type Group = { key: string; code: MiaCode; recipient: string; stream: MiaStream; rows: Cand[]; due_at: string };
function groupCands(list: Cand[]): Group[] {
  const m = new Map<string, Group>();
  for (const c of list) {
    const stream: MiaStream = c.is_kid ? "kids" : "adult";
    const rcpt = String(c.recipient || "").toLowerCase();
    const key = c.code === "T4" ? `T4|${c.period_key}|${rcpt}` : `${rcpt}|${c.code}|${stream}`;
    let g = m.get(key);
    if (!g) { g = { key, code: c.code, recipient: rcpt, stream, rows: [], due_at: c.due_at }; m.set(key, g); }
    g.rows.push(c);
    if (new Date(c.due_at).getTime() < new Date(g.due_at).getTime()) g.due_at = c.due_at;
  }
  const byName = (a: Cand, b: Cand) => String(a.first_name || "").localeCompare(String(b.first_name || ""), "en", { sensitivity: "base" })
    || a.student_id.localeCompare(b.student_id);
  return [...m.values()].map((g) => ({ ...g, rows: g.rows.sort(byName) }))
    // due_at, then T4 AFTER every member email due at the same instant: T4 reports
    // what the member received this episode, so its M4 must already be sent.
    .sort((x, y) => new Date(x.due_at).getTime() - new Date(y.due_at).getTime()
      || (x.code === "T4" ? 1 : 0) - (y.code === "T4" ? 1 : 0)
      || x.key.localeCompare(y.key));
}
const groupNames = (rows: Cand[]) => rows.map((r) => String(r.first_name || "").trim()).filter(Boolean);

// ONE AUTOMATED EMAIL PER ADDRESS PER SYDNEY DAY (migration 144). When an address
// has several groups due, the most advanced stage must be the one that goes: the
// address's groups are reordered among the SAME positions they already hold in
// the run order, highest stage first (M4, M3, M2, M1, then R). The global order
// of positions (due_at, T4 after its M4, key) is untouched, and an M4 can only
// move earlier, so a T4 still follows its M4. Ranks mirror mia_codes.seq.
const STAGE_RANK: Record<string, number> = { M4: 4, M3: 3, M2: 2, M1: 1, R: 0 };
function highestStageFirst(groups: Group[]): Group[] {
  const slots = new Map<string, number[]>();
  groups.forEach((g, i) => {
    if (g.code === "T4") return;
    (slots.get(g.recipient) || slots.set(g.recipient, []).get(g.recipient)!).push(i);
  });
  const out = groups.slice();
  for (const idx of slots.values()) {
    if (idx.length < 2) continue;
    const mine = idx.map((i) => groups[i]).sort((a, b) => (STAGE_RANK[b.code] ?? -1) - (STAGE_RANK[a.code] ?? -1)
      || new Date(a.due_at).getTime() - new Date(b.due_at).getTime() || a.key.localeCompare(b.key));
    idx.forEach((pos, k) => { out[pos] = mine[k]; });
  }
  return out;
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
    const daysOf = await readMiaDays(sb);
    // test_set: "all" (default) = every code x both streams + the plural kids copy;
    // "plural" = only the plural kids copy (M1 to M4 and R, three fixture children).
    const testSet = body.test_set === "plural" ? "plural" : "all";
    const results = [];
    const testSender = createPacedSender();
    for (const stream of (testSet === "plural" ? [] : ["adult", "kids"]) as MiaStream[]) {
      const u = units[stream]!;
      for (const code of MIA_CODES) {
        if (code === "T4" && !daysOf) {
          results.push({ stream, code, ok: false, skipped: "public.mia_codes could not be read: no T4 in this run" });
          continue;
        }
        const c: Cand = {
          ...fixtureFor(stream, code, to),
          unit_name: String(u.name || "").trim(), unit_legacy_id: u.legacy_id ? String(u.legacy_id).toLowerCase() : null,
          unit_address: u.address, unit_phone: u.phone ? String(u.phone).trim() || null : null,
        };
        const msg = await render(c, daysOf, code, stream);
        const subject = TEST_SUBJECT_PREFIX + msg.subject;
        const r = await sendViaResend(testSender, to, { ...msg, subject });
        results.push({ stream, code, subject, ok: r.ok, ...(r.ok ? {} : { error: r.error }) });
      }
    }
    // The plural kids copy: one email per code naming FIXTURE_SIBLINGS.
    for (const code of MIA_CODES.filter((k) => k !== "T4")) {
      const u = units.kids!;
      const c: Cand = {
        ...fixtureFor("kids", code, to),
        unit_name: String(u.name || "").trim(), unit_legacy_id: u.legacy_id ? String(u.legacy_id).toLowerCase() : null,
        unit_address: u.address, unit_phone: u.phone ? String(u.phone).trim() || null : null,
      };
      const msg = await render(c, daysOf, code, "kids", undefined, FIXTURE_SIBLINGS);
      const subject = TEST_SUBJECT_PREFIX + msg.subject;
      const r = await sendViaResend(testSender, to, { ...msg, subject });
      results.push({ stream: "kids", code, plural: true, children: FIXTURE_SIBLINGS, subject, ok: r.ok, ...(r.ok ? {} : { error: r.error }) });
    }
    return json({
      mode: "test", to, test_set: testSet, wrote: "nothing",
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
  // The schedule, once per run. Unreadable -> no T4 this run (left unclaimed, so
  // still due next run); member emails are unaffected.
  const daysOf = await readMiaDays(supabase);
  const t4Held = daysOf ? 0 : cands.filter((c) => c.code === "T4").length;
  const sendable = cands.filter((c) => daysOf || c.code !== "T4");
  // The budget and the daily cap count EMAILS: one per group.
  const groups = highestStageFirst(groupCands(sendable));

  // One automated email per address per Sydney day (144): has this address had
  // one today? Asked once per address per run. null = the check failed.
  const sentTodayCache = new Map<string, boolean | null>();
  let rpcError: string | null = null;
  const hadEmailToday = async (addr: string): Promise<boolean | null> => {
    if (sentTodayCache.has(addr)) return sentTodayCache.get(addr)!;
    const { data, error } = await supabase.rpc("email_sent_today", { p_email: addr, p_now: now.toISOString() });
    const v = error ? null : data === true ? true : data === false ? false : null;
    if (v === null && !rpcError) {
      rpcError = error ? (error.message || String(error)) : "unexpected result from email_sent_today";
      console.error("[mia-emails] email_sent_today failed — no member email this run:", rpcError);
    }
    sentTodayCache.set(addr, v);
    return v;
  };
  // The run plan, shared by the dry run and the send loop: for each group, in
  // order, would it go now? Member groups: not if the check failed (fail closed),
  // not if the address already had an email today or earlier in THIS run. T4 is
  // never limited. Deferred groups stay due and do not use the budget.
  type Plan = "send" | "deferred_daily_limit" | "not_sent_rpc_error" | "over_daily_cap_next_run";
  const planFor = async (g: Group, used: number, sentThisRun: Set<string>): Promise<Plan> => {
    if (g.code !== "T4") {
      if (rpcError) return "not_sent_rpc_error";
      if (sentThisRun.has(g.recipient)) return "deferred_daily_limit";
      const st = await hadEmailToday(g.recipient);
      if (st === null) return "not_sent_rpc_error";
      if (st) return "deferred_daily_limit";
    }
    return used < budget ? "send" : "over_daily_cap_next_run";
  };

  // T4's "Automated emails sent" in a dry run: what is logged, plus the M4 this run
  // would send for the same episode (an M4 group sorts no later than its T4).
  const willSend = new Set<string>();
  const dryPlan: Plan[] = [];
  if (!send) {
    const sentThisRun = new Set<string>();
    let used = 0;
    for (const g of groups) {
      const pl = await planFor(g, used, sentThisRun);
      dryPlan.push(pl);
      if (pl === "send") { used++; if (g.code !== "T4") sentThisRun.add(g.recipient); g.rows.forEach((c) => willSend.add(c.period_key)); }
    }
  }
  const dryAutomated = (t: Cand): MiaSent => {
    const m4 = t.period_key.replace(/:T4$/, ":M4");
    const codes = [...(t.sent_codes || []), ...(willSend.has(m4) ? ["M4"] : [])];
    return { codes, reason: noneReason(t.member_reach, false) };
  };
  const renderGroup = (g: Group, automated?: MiaSent) =>
    render(g.rows[0], daysOf, g.code, g.stream, automated, groupNames(g.rows));

  // ---------------- DRY RUN: write nothing ----------------
  if (!send) {
    const due = [];
    for (const [i, g] of groups.entries()) {
      const msg = await renderGroup(g, g.code === "T4" ? dryAutomated(g.rows[0]) : undefined);
      const pl = dryPlan[i];
      due.push({
        action: pl === "send" ? (g.rows.some((c) => c.attempt_status === "failed") ? "would_retry" : "would_send") : pl,
        code: g.code, stream: g.stream, recipient: g.recipient, due_at: g.due_at,
        children: g.stream === "kids" ? groupNames(g.rows) : undefined,
        members: g.stream === "adult" ? groupNames(g.rows) : undefined,
        students: g.rows.length, subject: msg.subject,
        rows: g.rows.map((c) => ({ student_id: c.student_id, period_key: c.period_key, first_name: c.first_name, academy: c.unit_name,
          last_class_date: c.last_class_date, days_absent: c.days_absent })),
      });
    }
    const samples = [];
    for (const stream of ["adult", "kids"] as MiaStream[]) {
      for (const code of MIA_CODES) {
        if (code === "T4" && !daysOf) { samples.push({ stream, code, skipped: "public.mia_codes could not be read: no T4 in this run" }); continue; }
        const real = cands.find((c) => (c.is_kid ? "kids" : "adult") === stream && c.code === code);
        const base = real || fixtureFor(stream, code, code === "T4" ? TEAM_ADDRESS : "sample@example.invalid");
        samples.push({ stream, code, to: base.recipient, from_real_member: !!real, ...(await render(base, daysOf, code, stream, real ? dryAutomated(real) : undefined)) });
      }
    }
    // The plural copy (2+ children): a real group when there is one, else fixture children.
    for (const code of MIA_CODES.filter((k) => k !== "T4")) {
      const realG = groups.find((g) => g.stream === "kids" && g.code === code && g.rows.length >= 2);
      const base = realG ? realG.rows[0] : fixtureFor("kids", code, "sample@example.invalid");
      const names = realG ? groupNames(realG.rows) : FIXTURE_SIBLINGS;
      samples.push({ stream: "kids", code, plural: true, children: names, to: base.recipient, from_real_member: !!realG,
        ...(await render(base, daysOf, code, "kids", undefined, names)) });
    }
    return json({
      mode: "dry_run", wrote: "nothing", now: now.toISOString(),
      daily_cap: envCap, emails_sent_today_all_kinds: emailsSentToday, max_per_run: MAX_EMAILS_PER_RUN, budget_this_run: budget,
      counts: {
        due_rows: cands.length,
        due_emails: groups.length,
        would_send: dryPlan.filter((x) => x === "send").length,
        rows_covered: groups.filter((_, i) => dryPlan[i] === "send").reduce((n, g) => n + g.rows.length, 0),
        of_which_retries: groups.filter((g, i) => dryPlan[i] === "send" && g.rows.some((c) => c.attempt_status === "failed")).length,
        over_daily_cap: dryPlan.filter((x) => x === "over_daily_cap_next_run").length,
        deferred_daily_limit: dryPlan.filter((x) => x === "deferred_daily_limit").length,
        not_sent_rpc_error: dryPlan.filter((x) => x === "not_sent_rpc_error").length,
        by_code: Object.fromEntries(MIA_CODES.map((k) => [k, groups.filter((g) => g.code === k).length])),
        t4_held_schedule_unreadable: t4Held,
      },
      warnings: [
        ...(Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: samples have no unsubscribe link, and send:true will refuse"]),
        ...(daysOf ? [] : ["public.mia_codes could not be read: no T4 would be sent this run"]),
        ...(rpcError ? [`email_sent_today failed (${rpcError}): no member email would be sent this run`] : []),
      ],
      rpc_error: rpcError,
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
  let rowsCovered = 0, rowsLeftOut = 0, deferredDaily = 0, rpcSkipped = 0;
  const sentThisRun = new Set<string>();
  let stopReason: string | null = null;
  const failures: unknown[] = [];
  const sender = createPacedSender(requestStart);
  for (const g of groups) {
    // One automated email per address per day (144): checked BEFORE claiming, so
    // a deferred group stays due (unclaimed) for the next run. Fail closed.
    const pl = await planFor(g, attempts, sentThisRun);
    if (pl === "deferred_daily_limit") { deferredDaily++; continue; }
    if (pl === "not_sent_rpc_error") { rpcSkipped++; continue; }
    // The budget counts EMAILS: one per group, however many students it covers.
    if (attempts >= budget) { overCap++; continue; }
    // Out of run time, or Resend said stop: leave it unclaimed; still due next run.
    if (!stopReason && !sender.canStartAnother()) stopReason = "run time budget reached";
    if (stopReason) { deferred++; continue; }
    // Claim EVERY row of the group before sending. A row already claimed or sent
    // (another run, or sent earlier) is left out; the rest still go.
    const claimed: { c: Cand; id: string }[] = [];
    for (const c of g.rows) {
      const id = await claim(c);
      if (id) claimed.push({ c, id });
      else { rowsLeftOut++; console.log(`[mia-emails] ${c.period_key} -> ${c.recipient}: already claimed or sent, left out of this email`); }
    }
    if (!claimed.length) { lostClaim++; continue; }
    attempts++;
    const rows = claimed.map((x) => x.c);
    // T4 reads the log fresh, so an M4 sent earlier in THIS run is listed.
    let automated: MiaSent | undefined;
    if (g.code === "T4") automated = await sentThisEpisode(rows[0]);
    const res = await sendViaResend(sender, g.recipient, await render(rows[0], daysOf, g.code, g.stream, automated, groupNames(rows)));
    retries429 += Math.max(0, res.attempts - 1);
    if (res.stop) stopReason = "Resend rate limit: " + (res.error || "429");
    // One outcome for the whole group: sent together, or failed together (and
    // retried together on the next run).
    const at = new Date().toISOString();
    for (const x of claimed) {
      await supabase.from("email_sends")
        .update(res.ok ? { status: "sent", error: null, sent_at: at } : { status: "failed", error: res.error || "send failed" })
        .eq("id", x.id);
    }
    if (res.ok) { sent++; rowsCovered += claimed.length; if (g.code !== "T4") sentThisRun.add(g.recipient); }
    else { failed++; failures.push({ recipient: g.recipient, code: g.code, students: groupNames(rows), error: res.error }); }
  }
  return json({
    mode: "send", now: now.toISOString(),
    daily_cap: envCap, emails_sent_today_before_run: emailsSentToday, budget_this_run: budget,
    emails_sent: sent, emails_failed: failed,
    groups_sent: sent, rows_covered: rowsCovered, rows_left_out: rowsLeftOut,
    deferred_daily_limit: deferredDaily, not_sent_rpc_error: rpcSkipped, rpc_error: rpcError,
    over_daily_cap: overCap, claimed_by_another_run: lostClaim,
    max_per_run: MAX_EMAILS_PER_RUN, deferred_to_next_run: deferred, stopped: stopReason,
    t4_held_schedule_unreadable: t4Held,
    retries_after_429: retries429, run_ms: sender.elapsedMs(),
    failures,
  }, 200);
});
