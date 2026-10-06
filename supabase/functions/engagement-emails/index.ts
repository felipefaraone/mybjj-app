// supabase/functions/engagement-emails/index.ts
//
// Engagement emails ENGINE (migration 137). Builds the monthly training recap
// and, ONLY when asked, sends it. Nothing schedules this function: it runs when
// someone calls it with the shared secret.
//
//   POST { kind: "monthly_recap", period: "YYYY-MM", send?: false|true, limit?: n }
//   POST { test_to: "<one address>", period?: "YYYY-MM" }   TEST SEND: the four
//        samples with fixture data to that address, subjects "[TEST] …"; touches
//        no table and ignores the daily cap.
//   header x-engagement-secret: <ENGAGEMENT_SECRET>
//
// ONE EMAIL PER RECIPIENT ADDRESS per kind + period. A parent with three kids,
// or an adult who trains and has kids, gets one email listing each student with
// their own number (themselves first, then kids by first name). Students at zero
// classes are left out; an address whose students are all at zero gets nothing.
//
// send:false (DEFAULT) — a dry run. Writes NOTHING. Returns the counts (emails =
//   addresses, students covered), every address with its students, and rendered
//   samples (one of them an address with two or more kids).
// send:true — sends through Resend the same way trial-booking does. Every student
//   in a sent email gets its own email_sends row (same status, same sent_at), so
//   an address emailed for this period is never emailed again for it — not even
//   when another student becomes eligible for it later (the dry run reports that
//   as already_done). The daily cap counts EMAILS (EMAIL_DAILY_CAP, default 90;
//   a smaller `limit` wins; never more than 60 per run, and a run stops starting
//   sends after 100 s, so it answers inside the 150 s request timeout); a second
//   run continues where this one stopped. Sends are paced at 2 a second with 429
//   retries (_shared/resend_send.ts). A failed send (Resend error, or a run that
//   died mid-send) is retried.
//
// kind "mia" is not implemented yet (the rule is still to come): 400.
//
// Who and how many come from the database, not from here:
//   monthly_recap_candidates(from, to)  — eligible = active and not on hold
//   training_count(...)                 — the app's Progress month rule
//   email_recipients_for_student(...)   — adult's own email; kid's guardians;
//                                         opt-outs removed
//
// Deploy with --no-verify-jwt: this is called with the shared secret, not a JWT.
//
// Secrets (supabase secrets set ...):
//   ENGAGEMENT_SECRET   shared secret for the x-engagement-secret header
//   EMAIL_UNSUB_SECRET  HMAC key for the unsubscribe links (shared with
//                       email-unsubscribe). Required to SEND; a dry run without
//                       it still renders, with no link and a warning.
//   RESEND_API_KEY      already set (trial-booking uses it)
//   EMAIL_DAILY_CAP     optional, default 90
// Unsubscribe links point at https://mybjj-app.com/unsubscribe.html (static).
// Auto-provided: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
// RESEND_API_URL is a TEST seam only (the local harness points it at a stub);
// leave it unset in production.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { renderLayout, type LayoutBlock } from "../_shared/email_layout.ts";
import { parseTestTo, TEST_SUBJECT_PREFIX } from "../_shared/test_to.ts";
import { createPacedSender, MAX_EMAILS_PER_RUN, type SendResult } from "../_shared/resend_send.ts";
type PacedSender = ReturnType<typeof createPacedSender>;

// ---- config -------------------------------------------------------------------
// Same verified Resend domain and reply-to as trial-booking; sender name "MyBJJ".
const FROM = "MyBJJ <noreply@mybjj-app.com>";
const REPLY_TO = "info@mybjj.com.au";
const SYDNEY_TZ = "Australia/Sydney";
const DEFAULT_DAILY_CAP = 90;
const PAGE = 1000; // PostgREST row cap: everything below is paginated
const MONTHS = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"];

// ---- helpers --------------------------------------------------------------------
function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Constant-time string compare (secret header, HMAC signatures).
function safeEqual(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function normEmail(e: string): string {
  return String(e || "").trim().toLowerCase();
}

// The ONE signing rule, shared byte-for-byte with email-unsubscribe.
export async function unsubSignature(secret: string, email: string, kind: string): Promise<string> {
  return await hmacHex(secret, normEmail(email) + "|" + kind);
}

// The footer link goes to the STATIC page, which changes nothing on load (email
// scanners open links by themselves); only a button there POSTs to
// email-unsubscribe. sig signs this email's kind, sig_all signs 'all' so the
// page can offer "Stop all emails from MyBJJ".
const UNSUB_PAGE = "https://mybjj-app.com/unsubscribe.html";
async function unsubUrl(email: string, kind: string): Promise<string | null> {
  const secret = Deno.env.get("EMAIL_UNSUB_SECRET");
  if (!secret) return null;
  const e = normEmail(email);
  const q = new URLSearchParams({
    email: e,
    kind,
    sig: await unsubSignature(secret, e, kind),
    sig_all: await unsubSignature(secret, e, "all"),
  });
  return `${UNSUB_PAGE}?${q.toString()}`;
}

function sydneyTodayStr(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: SYDNEY_TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date());
}

// 'YYYY-MM' -> first/last day and the month's name. null when malformed.
function monthBounds(period: string): { from: string; to: string; label: string } | null {
  const m = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(period);
  if (!m) return null;
  const y = +m[1], mo = +m[2];
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  return { from: `${period}-01`, to: `${period}-${String(last).padStart(2, "0")}`, label: MONTHS[mo - 1] };
}

// ---- template ---------------------------------------------------------------------
// ONE email per recipient address: it lists every student that address receives
// for, each with their own number. The recipient themselves first (when they are
// one of the students), then each kid by first name, kids sorted by first name.
// Students with zero classes are not in `lines` at all (the caller drops them).
interface RecapLine {
  self: boolean;     // the recipient IS this student (an adult's own address)
  first: string;     // the student's first name
  n: number;         // classes in the month (> 0)
}
interface RecapData {
  lines: RecapLine[];     // ordered: self first, then kids by first name
  recipientName: string;  // guardian's first name when known, "" otherwise
  monthLabel: string;     // "September"
  unsubscribeUrl: string | null;
}

// =============================== PLACEHOLDER COPY ===============================
// The head instructor is writing the real wording. Everything inside
// recapCopy() is a stand-in; the layout in renderRecap (header, card, footer,
// unsubscribe) is the part that stays.
// =================================================================================
function recapCopy(d: RecapData): { subject: string; greeting: string; lines: string[] } {
  const times = (n: number) => (n === 1 ? "1 time" : `${n} times`);
  const self = d.lines.find((l) => l.self);
  const others = d.lines.filter((l) => !l.self);
  // Subject: about you when you are one of the students; else the kid, or the family.
  const subject = self
    ? `Your training in ${d.monthLabel}`
    : others.length === 1
    ? `${others[0].first}'s training in ${d.monthLabel}`
    : `Your family's training in ${d.monthLabel}`;
  const greeting = self && self.first
    ? `Hi ${self.first},`
    : d.recipientName ? `Hi ${d.recipientName},` : "Hi there,";
  // The month goes on the first line only.
  const lines = d.lines.map((l, i) => {
    const month = i === 0 ? ` in ${d.monthLabel}` : "";
    return l.self ? `You trained ${times(l.n)}${month}.` : `${l.first} trained ${times(l.n)}${month}.`;
  });
  return { subject, greeting, lines };
}
// ============================ END PLACEHOLDER COPY ============================

// The plain text is built here; the HTML is the shared layout, which escapes
// every value.
export function renderRecap(d: RecapData): { subject: string; html: string; text: string } {
  const c = recapCopy(d);
  const unsub = d.unsubscribeUrl || "";
  const text = [
    "MyBJJ",
    "",
    c.greeting,
    "",
    ...c.lines,
    "",
    "See you on the mats,",
    "MyBJJ",
    "",
    "You're getting this because you train at MyBJJ (or a child you look after does).",
    unsub ? `Don't want these emails? Unsubscribe: ${unsub}` : "",
  ].join("\n");
  // HTML: the shared layout (_shared/email_layout.ts). No button: this email has
  // no call to action.
  const html = renderLayout({
    subject: c.subject,
    blocks: [
      { t: "p", parts: [c.greeting] },
      ...c.lines.map((l): LayoutBlock => ({ t: "stat", text: l })),
      { t: "sign", lines: ["See you on the mats,", "MyBJJ"] },
    ],
    footer: {
      why: "You're getting this because you train at MyBJJ (or a child you look after does).",
      unsubscribeUrl: unsub || null,
    },
  });
  return { subject: c.subject, html, text };
}

// Same request as before (from / reply_to / subject / html / text), through the
// paced sender (_shared/resend_send.ts): 2 a second, 429s waited out and retried.
// Never throws: returns ok or the error text.
function sendViaResend(sender: PacedSender, to: string, msg: { subject: string; html: string; text: string }): Promise<SendResult> {
  return sender.send({ from: FROM, to: [to], reply_to: REPLY_TO, subject: msg.subject, html: msg.html, text: msg.text });
}

// ---- data -------------------------------------------------------------------------
type Cand = {
  student_id: string; student_name: string; first_name: string; is_kid: boolean;
  n: number; email: string | null; display_name: string | null; is_guardian: boolean | null;
};
type SendRow = { id: string; student_id: string | null; recipient_email: string; status: string };

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

// ---- handler ------------------------------------------------------------------------
Deno.serve(async (req) => {
  const requestStart = Date.now();
  // 1. Shared secret. Unset secret = nobody gets in (fail closed).
  const expected = Deno.env.get("ENGAGEMENT_SECRET") || "";
  const given = req.headers.get("x-engagement-secret") || "";
  if (!expected || !safeEqual(given, expected)) return json({ error: "unauthorized" }, 401);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  // TEST SEND: the four recap samples with FIXTURE data (never real students) to
  // ONE address, subjects "[TEST] …". Reads and writes nothing in the database;
  // no daily cap. Month: `period` when given and valid, else last month.
  if (body.test_to !== undefined) {
    const to = parseTestTo(body.test_to);
    if (!to) return json({ error: "test_to must be one valid email address" }, 400);
    const last = new Date(sydneyTodayStr() + "T00:00:00Z"); last.setUTCDate(0);
    const label = monthBounds(String(body.period || ""))?.label || MONTHS[last.getUTCMonth()];
    const fixtures: [string, RecapLine[], string][] = [
      ["self_only", [{ self: true, first: "Sam", n: 8 }], ""],
      ["self_and_kids", [{ self: true, first: "Sam", n: 8 }, { self: false, first: "Alex", n: 5 }, { self: false, first: "Charlotte", n: 6 }], ""],
      ["two_or_more_kids", [{ self: false, first: "Kira", n: 2 }, { self: false, first: "Max", n: 3 }], "Jo"],
      ["one_kid", [{ self: false, first: "Mia", n: 1 }], "Jo"],
    ];
    const results = [];
    const testSender = createPacedSender();
    for (const [sample, lines, recipientName] of fixtures) {
      const msg = renderRecap({ lines, recipientName, monthLabel: label, unsubscribeUrl: await unsubUrl(to, "monthly_recap") });
      const subject = TEST_SUBJECT_PREFIX + msg.subject;
      const r = await sendViaResend(testSender, to, { ...msg, subject });
      results.push({ sample, subject, ok: r.ok, ...(r.ok ? {} : { error: r.error }) });
    }
    return json({
      mode: "test", to, wrote: "nothing",
      sent: results.filter((x) => x.ok).length, failed: results.filter((x) => !x.ok).length,
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: no unsubscribe link in the test emails"],
      results,
    }, 200);
  }

  const kind = String(body.kind || "");
  if (kind === "mia") return json({ error: "not configured yet" }, 400);
  if (kind !== "monthly_recap") return json({ error: "kind must be monthly_recap" }, 400);
  const period = String(body.period || "");
  const bounds = monthBounds(period);
  if (!bounds) return json({ error: "period must be YYYY-MM" }, 400);
  const send = body.send === true;   // anything else is a dry run
  const envCap = Math.max(0, parseInt(Deno.env.get("EMAIL_DAILY_CAP") || "", 10) || DEFAULT_DAILY_CAP);
  const reqLimit = body.limit == null ? null : parseInt(String(body.limit), 10);
  if (reqLimit != null && (!Number.isFinite(reqLimit) || reqLimit < 0)) return json({ error: "limit must be a positive number" }, 400);
  // Per run: EMAIL_DAILY_CAP, a smaller `limit`, and never more than
  // MAX_EMAILS_PER_RUN so the run answers inside the 150 s request timeout.
  const cap = Math.min(reqLimit == null ? envCap : Math.min(reqLimit, envCap), MAX_EMAILS_PER_RUN);

  if (send) {
    // A recap of a month that hasn't ended would undercount. Sydney calendar.
    if (bounds.to >= sydneyTodayStr()) return json({ error: `${bounds.label} ${period.slice(0, 4)} isn't over yet` }, 400);
    if (!Deno.env.get("EMAIL_UNSUB_SECRET")) return json({ error: "EMAIL_UNSUB_SECRET not set: refusing to send without an unsubscribe link" }, 500);
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let cands: Cand[];
  let done: SendRow[];
  try {
    cands = await fetchAllPages<Cand>((a, b) =>
      supabase.rpc("monthly_recap_candidates", { p_from: bounds.from, p_to: bounds.to }).range(a, b));
    done = await fetchAllPages<SendRow>((a, b) =>
      supabase.from("email_sends").select("id, student_id, recipient_email, status")
        .eq("kind", kind).eq("period_key", period).order("id", { ascending: true }).range(a, b));
  } catch (e) {
    return json({ error: "read failed", detail: e instanceof Error ? e.message : String(e) }, 500);
  }
  // ---- Group by RECIPIENT ADDRESS: one email per address per kind + period ----
  type Who = { id: string; name: string; first: string; isKid: boolean; n: number; self: boolean };
  type Addr = { email: string; guardianName: string; students: Who[] };
  const addrs = new Map<string, Addr>();
  const studentIds = new Set<string>();
  const withRecipient = new Set<string>();
  const nOf = new Map<string, number>();
  for (const c of cands) {
    studentIds.add(c.student_id);
    nOf.set(c.student_id, Number(c.n) || 0);
    if (!c.email) continue;
    withRecipient.add(c.student_id);
    const e = normEmail(c.email);
    let a = addrs.get(e);
    if (!a) { a = { email: e, guardianName: "", students: [] }; addrs.set(e, a); }
    if (c.is_guardian && !a.guardianName && c.display_name) a.guardianName = c.display_name;
    if (!a.students.some((x) => x.id === c.student_id)) {
      a.students.push({ id: c.student_id, name: c.student_name, first: c.first_name || "", isKid: !!c.is_kid,
        n: Number(c.n) || 0, self: !c.is_guardian });
    }
  }
  // Order inside an email: the recipient's own record first, then the rest by
  // first name. (Two "self" records on one address is rare: the first is "you",
  // any other is listed by name.)
  for (const a of addrs.values()) {
    a.students.sort((x, y) => (x.self === y.self ? 0 : x.self ? -1 : 1) || x.first.localeCompare(y.first) || x.id.localeCompare(y.id));
    let seenSelf = false;
    for (const w of a.students) { if (w.self) { if (seenSelf) w.self = false; else seenSelf = true; } }
  }
  const addrList = [...addrs.values()].sort((x, y) => x.email.localeCompare(y.email));
  const noRecipient = [...studentIds].filter((id) => !withRecipient.has(id));
  const studentName = new Map<string, string>(cands.map((c) => [c.student_id, c.student_name]));

  // What the log says about each address for this kind + period.
  //   sent    -> the address was emailed: NEVER email it again this period, even
  //              if another student has become eligible for it since.
  //   skipped -> every student it had was at zero classes: done as well.
  //   failed  -> a send error or a run that died mid-send: retried.
  const priorByAddr = new Map<string, SendRow[]>();
  for (const r of done) {
    const e = normEmail(r.recipient_email);
    (priorByAddr.get(e) || priorByAddr.set(e, []).get(e)!).push(r);
  }
  const addrState = (e: string): "sent" | "skipped" | "failed" | "new" => {
    const rows = priorByAddr.get(e) || [];
    if (rows.some((r) => r.status === "sent")) return "sent";
    if (rows.some((r) => r.status === "failed")) return "failed";
    if (rows.length && rows.every((r) => r.status === "skipped")) return "skipped";
    return "new";
  };

  const firstWord = (s: string) => String(s || "").trim().split(/\s+/)[0] || "";
  const included = (a: Addr) => a.students.filter((w) => w.n > 0);
  const build = async (a: Addr) =>
    renderRecap({
      lines: included(a).map((w) => ({ self: w.self, first: w.first, n: w.n })),
      recipientName: firstWord(a.guardianName),
      monthLabel: bounds.label,
      unsubscribeUrl: await unsubUrl(a.email, kind),
    });

  const studentCounts = {
    eligible_students: studentIds.size,
    students_with_classes: [...nOf.values()].filter((n) => n > 0).length,
    students_with_zero_classes: [...nOf.values()].filter((n) => n === 0).length,
    students_without_recipient: noRecipient.length,
  };

  // ---------------- DRY RUN: write nothing ----------------
  if (!send) {
    const recipients: unknown[] = [];
    let emailsToSend = 0, studentsCovered = 0, allZero = 0, already = 0;
    for (const a of addrList) {
      const st = addrState(a.email);
      const inc = included(a);
      let action: string;
      if (st === "sent" || st === "skipped") { action = "already_done"; already++; }
      else if (!inc.length) { action = "no_email_all_zero_classes"; allZero++; }
      else { action = st === "failed" ? "would_retry" : "would_send"; emailsToSend++; studentsCovered += inc.length; }
      const loggedIds = new Set((priorByAddr.get(a.email) || []).map((r) => r.student_id));
      recipients.push({
        recipient: a.email,
        action,
        subject: inc.length ? (await build(a)).subject : null,
        students: a.students.map((w) => ({
          student: w.name, student_id: w.id, kid: w.isKid, self: w.self, number: w.n, in_email: w.n > 0,
          ...(action === "already_done" && !loggedIds.has(w.id) ? { note: "became eligible after this address was emailed; not sent again" } : {}),
        })),
      });
    }
    const sendable = addrList.filter((a) => addrState(a.email) !== "sent" && addrState(a.email) !== "skipped" && included(a).length);
    const pick = (f: (a: Addr) => boolean) => sendable.find(f) || addrList.find((a) => included(a).length && f(a));
    const sampleAddrs: [string, Addr | undefined][] = [
      ["self_only", pick((a) => included(a).length === 1 && included(a)[0].self)],
      ["self_and_kids", pick((a) => included(a).some((w) => w.self) && included(a).length >= 2)],
      ["two_or_more_kids", pick((a) => !included(a).some((w) => w.self) && included(a).length >= 2)],
      ["one_kid", pick((a) => !included(a).some((w) => w.self) && included(a).length === 1)],
    ];
    const samples = [];
    for (const [label, a] of sampleAddrs) {
      if (!a) { samples.push({ sample: label, missing: "no address in this period fits" }); continue; }
      samples.push({ sample: label, to: a.email, ...(await build(a)) });
    }
    return json({
      mode: "dry_run", kind, period, wrote: "nothing",
      cap_per_run: cap,
      counts: {
        ...studentCounts,
        addresses: addrList.length,
        emails_to_send: emailsToSend,
        students_covered: studentsCovered,
        addresses_all_zero_classes: allZero,
        already_done: already,
      },
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: samples have no unsubscribe link, and send:true will refuse"],
      students_without_recipient: noRecipient.map((id) => ({ student: studentName.get(id) || "", student_id: id })),
      recipients,
      samples,
    }, 200);
  }

  // ---------------- SEND ----------------
  // The cap counts EMAILS (addresses). Every student in a sent email gets its own
  // email_sends row (same status, same sent_at), so no later run re-sends any of
  // them or sends that address a second email for this period.
  let sent = 0, failed = 0, allZero = 0, already = 0, remaining = 0, attempts = 0, lostClaim = 0, studentsCovered = 0;
  let retries429 = 0;
  let stopReason: string | null = null;
  const sender = createPacedSender(requestStart);
  const failures: unknown[] = [];
  const priorRow = (sid: string, e: string) => (priorByAddr.get(e) || []).find((r) => r.student_id === sid);
  for (const a of addrList) {
    const st = addrState(a.email);
    if (st === "sent" || st === "skipped") { already++; continue; }
    const inc = included(a);
    if (!inc.length) {
      // Every student at zero: no email; recorded so the dry run shows it done.
      for (const w of a.students) {
        await supabase.from("email_sends").insert({
          kind, period_key: period, student_id: w.id, recipient_email: a.email, status: "skipped", error: "zero classes",
        });
      }
      allZero++;
      continue;
    }
    if (attempts >= cap) { remaining++; continue; }
    // Out of run time, or Resend said stop: leave it unclaimed for the next run.
    if (!stopReason && !sender.canStartAnother()) stopReason = "run time budget reached";
    if (stopReason) { remaining++; continue; }
    // CLAIM every included student's row before sending (insert, or re-take a
    // 'failed' one). If any of them is held by another run, leave the address.
    const rowIds: string[] = [];
    let claimed = true;
    for (const w of inc) {
      const p = priorRow(w.id, a.email);
      let id: string | null = null;
      if (p) {
        const { data, error } = await supabase.from("email_sends")
          .update({ status: "failed", error: "sending", sent_at: null })
          .eq("id", p.id).eq("status", "failed").select("id");
        if (!error && data && data.length) id = data[0].id;
      } else {
        const { data, error } = await supabase.from("email_sends").insert({
          kind, period_key: period, student_id: w.id, recipient_email: a.email, status: "failed", error: "sending",
        }).select("id");
        if (!error && data && data.length) id = data[0].id;
      }
      if (!id) { claimed = false; break; }
      rowIds.push(id);
    }
    if (!claimed) { lostClaim++; continue; }   // rows we did take stay 'failed' -> retried next run
    attempts++;
    const res = await sendViaResend(sender, a.email, await build(a));
    retries429 += Math.max(0, res.attempts - 1);
    if (res.stop) stopReason = "Resend rate limit: " + (res.error || "429");
    const at = new Date().toISOString();
    for (const id of rowIds) {
      await supabase.from("email_sends")
        .update(res.ok ? { status: "sent", error: null, sent_at: at } : { status: "failed", error: res.error || "send failed" })
        .eq("id", id);
    }
    if (res.ok) { sent++; studentsCovered += inc.length; }
    else { failed++; failures.push({ recipient: a.email, students: inc.map((w) => w.name), error: res.error }); }
  }
  return json({
    mode: "send", kind, period, cap_per_run: cap,
    emails_sent: sent, emails_failed: failed, students_covered: studentsCovered,
    addresses_all_zero_classes: allZero, already_done: already,
    remaining, claimed_by_another_run: lostClaim,
    max_per_run: MAX_EMAILS_PER_RUN, stopped: stopReason, retries_after_429: retries429, run_ms: sender.elapsedMs(),
    students_without_recipient: noRecipient.length,
    failures,
    next: remaining > 0 ? "Run again (e.g. tomorrow) to continue; addresses already emailed are skipped." : "Done for this period.",
  }, 200);
});
