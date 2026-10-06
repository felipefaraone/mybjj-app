// supabase/functions/engagement-emails/index.ts
//
// Engagement emails ENGINE (migration 137). Builds the monthly training recap
// for every eligible student and, ONLY when asked, sends it. Nothing schedules
// this function: it runs when someone calls it with the shared secret.
//
//   POST { kind: "monthly_recap", period: "YYYY-MM", send?: false|true, limit?: n }
//   header x-engagement-secret: <ENGAGEMENT_SECRET>
//
// send:false (DEFAULT) — a dry run. Writes NOTHING. Returns the counts, the full
//   recipient list (student, recipient, number) and three fully rendered sample
//   emails: an adult, a kid with guardians, and someone with zero classes.
// send:true — sends through Resend the same way trial-booking does, records every
//   attempt in public.email_sends, skips anything already sent (or skipped) for
//   this kind + period + student + recipient, and stops after the daily cap
//   (EMAIL_DAILY_CAP, default 90; a smaller `limit` wins). A second run the next
//   day continues where this one stopped. A row left 'failed' (a Resend error, or
//   a run that died mid-send) is retried by the next run.
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

function escHtml(s: unknown): string {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
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
// =============================== PLACEHOLDER COPY ===============================
// The head instructor is writing the real wording. Everything inside
// recapCopy() is a stand-in; the layout below it (header, card, footer,
// unsubscribe) is the part that stays.
// =================================================================================
function recapCopy(d: RecapData): { subject: string; greeting: string; line: string } {
  const times = d.n === 1 ? "1 time" : `${d.n} times`;
  if (d.isKid) {
    return {
      subject: `${d.firstName}'s training in ${d.monthLabel}`,
      greeting: d.recipientName ? `Hi ${d.recipientName},` : "Hi there,",
      line: `${d.firstName} trained ${times} in ${d.monthLabel}.`,
    };
  }
  return {
    subject: `Your training in ${d.monthLabel}`,
    greeting: d.firstName ? `Hi ${d.firstName},` : "Hi there,",
    line: `You trained ${times} in ${d.monthLabel}.`,
  };
}
// ============================ END PLACEHOLDER COPY ============================

interface RecapData {
  isKid: boolean;
  firstName: string;      // the student's first name
  recipientName: string;  // guardian display name (kids), "" if unknown
  n: number;
  monthLabel: string;     // "October"
  unsubscribeUrl: string | null;
}

// Same simple inline-styled grammar as trial-booking's emails (no external CSS,
// fonts or images). Every interpolated value goes through escHtml.
export function renderRecap(d: RecapData): { subject: string; html: string; text: string } {
  const c = recapCopy(d);
  const unsub = d.unsubscribeUrl || "";
  const text = [
    "MyBJJ",
    "",
    c.greeting,
    "",
    c.line,
    "",
    "See you on the mats,",
    "MyBJJ",
    "",
    "You're getting this because you train at MyBJJ (or a child you look after does).",
    unsub ? `Don't want these emails? Unsubscribe: ${unsub}` : "",
  ].join("\n");
  const html = `<div style="margin:0;padding:0;background:#f5f7fa">
  <div style="max-width:560px;margin:0 auto;padding:24px 20px;font-family:Arial,Helvetica,sans-serif;color:#16202b">
    <div style="background:#124680;border-bottom:3px solid #1A5DAD;border-radius:10px 10px 0 0;padding:14px 18px;color:#ffffff;font-size:18px;font-weight:700;letter-spacing:.5px">MyBJJ</div>
    <div style="background:#ffffff;border:1px solid #e1e7ee;border-top:none;border-radius:0 0 10px 10px;padding:18px 18px 20px;margin:0 0 22px">
      <p style="font-size:16px;margin:0 0 12px">${escHtml(c.greeting)}</p>
      <p style="font-size:18px;font-weight:700;color:#16202b;line-height:1.5;margin:0">${escHtml(c.line)}</p>
    </div>
    <p style="font-size:14px;color:#5a6a78;line-height:1.6;margin:0;border-top:1px solid #e1e7ee;padding-top:16px">
      See you on the mats,<br>
      <strong style="color:#16202b">MyBJJ</strong>
    </p>
    <p style="font-size:12px;color:#93a0ac;line-height:1.6;margin:14px 0 0">
      You're getting this because you train at MyBJJ (or a child you look after does).${unsub
        ? `<br><a href="${escHtml(unsub)}" style="color:#5a6a78;text-decoration:underline">Unsubscribe from these emails</a>`
        : ""}
    </p>
  </div>
</div>`;
  return { subject: c.subject, html, text };
}

// Send exactly the way trial-booking does (Resend HTTP API, from / reply_to /
// subject / html / text). Never throws: returns ok or the error text.
async function sendViaResend(to: string, msg: { subject: string; html: string; text: string }):
  Promise<{ ok: boolean; error?: string }> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return { ok: false, error: "RESEND_API_KEY not set" };
  const url = Deno.env.get("RESEND_API_URL") || "https://api.resend.com/emails";
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [to], reply_to: REPLY_TO, subject: msg.subject, html: msg.html, text: msg.text }),
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
  // 1. Shared secret. Unset secret = nobody gets in (fail closed).
  const expected = Deno.env.get("ENGAGEMENT_SECRET") || "";
  const given = req.headers.get("x-engagement-secret") || "";
  if (!expected || !safeEqual(given, expected)) return json({ error: "unauthorized" }, 401);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

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
  const cap = reqLimit == null ? envCap : Math.min(reqLimit, envCap);

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
  const doneKey = (sid: string, email: string) => sid + "|" + normEmail(email);
  const prior = new Map<string, SendRow>();
  for (const r of done) if (r.student_id) prior.set(doneKey(r.student_id, r.recipient_email), r);

  // Group the candidate rows by student (one row per recipient; a null email
  // means the student has nobody to send to).
  type Stu = { id: string; name: string; first: string; isKid: boolean; n: number;
    recipients: { email: string; name: string; isGuardian: boolean }[] };
  const students = new Map<string, Stu>();
  for (const c of cands) {
    let s = students.get(c.student_id);
    if (!s) {
      s = { id: c.student_id, name: c.student_name, first: c.first_name, isKid: !!c.is_kid, n: Number(c.n) || 0, recipients: [] };
      students.set(c.student_id, s);
    }
    if (c.email) s.recipients.push({ email: normEmail(c.email), name: c.display_name || "", isGuardian: !!c.is_guardian });
  }
  const list = [...students.values()];
  const noRecipient = list.filter((s) => !s.recipients.length);

  const firstWord = (s: string) => String(s || "").trim().split(/\s+/)[0] || "";
  const build = async (s: Stu, r: { email: string; name: string }) =>
    renderRecap({
      isKid: s.isKid, firstName: s.first, recipientName: firstWord(r.name), n: s.n,
      monthLabel: bounds.label, unsubscribeUrl: await unsubUrl(r.email, kind),
    });

  // ---------------- DRY RUN: write nothing ----------------
  if (!send) {
    const recipients: unknown[] = [];
    let wouldSend = 0, zero = 0, already = 0;
    for (const s of list) {
      for (const r of s.recipients) {
        const p = prior.get(doneKey(s.id, r.email));
        let action: string;
        if (p && (p.status === "sent" || p.status === "skipped")) { action = "already_" + p.status; already++; }
        else if (s.n === 0) { action = "skip_zero_classes"; zero++; }
        else { action = p ? "would_retry" : "would_send"; wouldSend++; }
        recipients.push({ student: s.name, student_id: s.id, kid: s.isKid, recipient: r.email, guardian: r.isGuardian, number: s.n, action });
      }
    }
    const pick = (f: (s: Stu) => boolean) => list.find((s) => s.recipients.length && f(s));
    const sampleStudents: [string, Stu | undefined][] = [
      ["adult", pick((s) => !s.isKid && s.n > 0)],
      ["kid_with_guardians", pick((s) => s.isKid && s.n > 0 && s.recipients.some((r) => r.isGuardian))],
      ["zero_classes", pick((s) => s.n === 0)],
    ];
    const samples = [];
    for (const [label, s] of sampleStudents) {
      if (!s) { samples.push({ sample: label, missing: "no student in this period fits" }); continue; }
      const r = s.recipients[0];
      samples.push({ sample: label, to: r.email, ...(await build(s, r)) });
    }
    return json({
      mode: "dry_run", kind, period, wrote: "nothing",
      cap_per_run: cap,
      counts: {
        eligible_students: list.length,
        students_with_classes: list.filter((s) => s.n > 0).length,
        students_with_zero_classes: list.filter((s) => s.n === 0).length,
        students_without_recipient: noRecipient.length,
        emails_to_send: wouldSend,
        zero_class_recipients: zero,
        already_done: already,
      },
      warnings: Deno.env.get("EMAIL_UNSUB_SECRET") ? [] : ["EMAIL_UNSUB_SECRET not set: samples have no unsubscribe link, and send:true will refuse"],
      students_without_recipient: noRecipient.map((s) => ({ student: s.name, student_id: s.id, kid: s.isKid })),
      recipients,
      samples,
    }, 200);
  }

  // ---------------- SEND ----------------
  let sent = 0, failed = 0, skippedZero = 0, already = 0, remaining = 0, attempts = 0, lostClaim = 0;
  const failures: unknown[] = [];
  const nowIso = () => new Date().toISOString();
  for (const s of list) {
    for (const r of s.recipients) {
      const p = prior.get(doneKey(s.id, r.email));
      if (p && (p.status === "sent" || p.status === "skipped")) { already++; continue; }
      if (s.n === 0) {
        // Recorded, never emailed. Doesn't count toward the cap.
        const { error } = await supabase.from("email_sends").insert({
          kind, period_key: period, student_id: s.id, recipient_email: r.email, status: "skipped", error: "zero classes",
        });
        if (!error) skippedZero++;
        continue;
      }
      if (attempts >= cap) { remaining++; continue; }
      // CLAIM before sending, so two overlapping runs can't both send: insert a
      // row (or re-take a 'failed' one); losing the race means someone else has it.
      let rowId: string | null = null;
      if (p) {
        const { data, error } = await supabase.from("email_sends")
          .update({ status: "failed", error: "sending", sent_at: null })
          .eq("id", p.id).eq("status", "failed").select("id");
        if (!error && data && data.length) rowId = data[0].id;
      } else {
        const { data, error } = await supabase.from("email_sends").insert({
          kind, period_key: period, student_id: s.id, recipient_email: r.email, status: "failed", error: "sending",
        }).select("id");
        if (!error && data && data.length) rowId = data[0].id;
      }
      if (!rowId) { lostClaim++; continue; }
      attempts++;
      const res = await sendViaResend(r.email, await build(s, r));
      if (res.ok) {
        sent++;
        await supabase.from("email_sends").update({ status: "sent", error: null, sent_at: nowIso() }).eq("id", rowId);
      } else {
        failed++;
        failures.push({ student: s.name, recipient: r.email, error: res.error });
        await supabase.from("email_sends").update({ status: "failed", error: res.error || "send failed" }).eq("id", rowId);
      }
    }
  }
  return json({
    mode: "send", kind, period, cap_per_run: cap,
    sent, failed, skipped_zero_classes: skippedZero, already_done: already,
    remaining, claimed_by_another_run: lostClaim,
    students_without_recipient: noRecipient.length,
    failures,
    next: remaining > 0 ? "Run again (e.g. tomorrow) to continue; already-sent addresses are skipped." : "Done for this period.",
  }, 200);
});
