// supabase/functions/trial-booking/index.ts
//
// Public trial-booking endpoint. This is the ONLY write path for the public
// booking form (mybjj-app.com/trial.html). It:
//   1. validates the Cloudflare Turnstile token server-side (the real spam gate),
//   2. validates the payload,
//   3. if a concrete class was picked, RE-VALIDATES it against the live timetable
//      (the client is never trusted — see the class validation block below),
//   4. inserts into public.trial_bookings with the service role (trial_status='booked'),
//   5. returns the row's waiver_token so the page can hand off to /waiver.html?t=...,
//   6. sends a confirmation email (via Resend) carrying the same waiver link, so a
//      person who closes the tab without clicking the CTA is still recoverable. The
//      email is redundancy, NEVER the critical path — a dead Resend still returns ok.
//
// The waiver is NO LONGER collected here — Phase 2 moved it to waiver.html, keyed
// by waiver_token. This function does not stamp waiver_signed_* anymore.
//
// Because the insert happens here (service role), the public page carries NO
// Supabase WRITE credentials (it only READS public_timetable with the publishable
// key), and the anon INSERT policy on trial_bookings is dropped and stays dropped.
//
// Deploy with --no-verify-jwt (public endpoint).
//
// Secrets required (supabase secrets set ...):
//   TURNSTILE_SECRET   - Cloudflare Turnstile secret key
//   RESEND_API_KEY     - Resend API key (already set for Auth SMTP; reused here)
// Auto-provided by the platform:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deno / Supabase Edge runtime.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { renderTrialEmail, trialUnsubUrl, TRIAL_FROM } from "../_shared/trial_emails.ts";
import { unitAddressLine } from "../_shared/unit_address.ts";

// ---- config -----------------------------------------------------------------

// Origins allowed to call this function (the booking page + local testing).
// Tighten/extend as needed.
const ALLOWED_ORIGINS = [
  "https://mybjj-app.com",
  "https://www.mybjj-app.com",
];

// The visitor can be no more than this many days ahead. The page projects the
// live weekly grid onto the next 21 days (3 weeks); we allow 22 (one day of slack) so a
// timezone edge never rejects a legitimate booking. Computed in Australia/Sydney.
const BOOKING_HORIZON_DAYS = 22;
const SYDNEY_TZ = "Australia/Sydney";

// Trial-bookable class types. MUST mirror trial.html's TRIAL_TYPES allow-list,
// but defined INDEPENDENTLY here — the page's list is a UX affordance, this is the
// control. The academy advertises these seven as trial entry points (jmma = Kids
// MMA, a real entry point). A first-timer must not book, even with a tampered or
// replayed request, the two live types deliberately left out:
//   adv  — their own site gates it at "3 stripe white belt+"
//   omat — unsupervised open training, not a first class
// (gi/fund are member class flavours with no trial card either.)
const TRIAL_TYPE_CODES = new Set(["beg", "alev", "nogi", "mma", "jmma", "jun", "mini"]);


// ---- confirmation email (Resend) --------------------------------------------
// Sender identity for the trial confirmation email. Kept as named constants so a
// domain / address change is a one-line edit. `mybjj-app.com` is the verified
// Resend domain; replies must land in the academy's real inbox, not a black hole.
const FROM = "myBJJ <noreply@mybjj-app.com>";
const REPLY_TO = "info@mybjj.com.au";
// Ops inbox that gets the "someone booked" heads-up (a SECOND, operational email).
const STAFF_NOTIFY_TO = "info@mybjj.com.au";
// Public origin the waiver link points at — must match trial.html's CTA host.
const WAIVER_ORIGIN = "https://mybjj-app.com";

// ---- helpers ----------------------------------------------------------------

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    // Kept IDENTICAL across all Edge Functions (no third variant). This function is
    // called from a plain page (trial.html) that only sends content-type, so the
    // extra allowed headers are an inert superset — harmless, and consistent.
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders(origin) },
  });
}

// A rejection the page can show verbatim. Always 400 with a short human message.
function bad(message: string, origin: string | null) {
  return json({ ok: false, error: message }, 400, origin);
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function str(v: unknown, max = 200): string {
  return (typeof v === "string" ? v : "").trim().slice(0, max);
}

// Tri-state on purpose: true / false / null, where null means "the client did
// not tell us". STRICTLY a JSON boolean — "true", "1", 1 and null all read as
// unanswered rather than being coerced. Coercion is how a malformed value turns
// into a quiet `false`, and a quiet `false` is the exact bug being fixed here:
// it is what recorded a child as an adult on every fallback booking.
function boolOrNull(v: unknown): boolean | null {
  return typeof v === "boolean" ? v : null;
}

// Title-case a person's name on the SERVER (the page is only an affordance):
// trim, collapse internal whitespace, uppercase the first letter of each word and
// lowercase the rest. Word boundaries include hyphen and apostrophe, so
// "mary-jane o'brien" -> "Mary-Jane O'Brien". No cleverness about particles
// (van / de / etc.) — that is explicitly out of scope.
function titleCase(s: string): string {
  return s.trim().replace(/\s+/g, " ").toLowerCase()
    .replace(/(^|[\s'-])(\p{L})/gu, (_m, sep, ch) => sep + ch.toUpperCase());
}

// 'HH:MM:SS' | 'HH:MM' -> 'HH:MM' so a Postgres `time` ('18:00:00') compares
// equal to what the page sends ('18:00').
function hhmm(v: string): string {
  return String(v || "").slice(0, 5);
}

// Today's date in Australia/Sydney as 'YYYY-MM-DD' (calendar date, not UTC).
function sydneyTodayStr(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: SYDNEY_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

// Child's date of birth (migration 136). Accepts 'YYYY-MM-DD' only; it must be a
// real calendar date, not after `todayStr`, and the child aged 2 to 17 on that
// day (the booking date, Sydney). Pure, so it is testable without the runtime.
// Returns the canonical date and the age, or the message to send back.
const KID_MIN_AGE = 2;
const KID_MAX_AGE = 17;
function ageOn(dob: string, onDate: string): number {
  const [by, bm, bd] = dob.split("-").map(Number);
  const [ty, tm, td] = onDate.split("-").map(Number);
  let age = ty - by;
  if (tm < bm || (tm === bm && td < bd)) age--;
  return age;
}
function checkKidDob(raw: string, todayStr: string): { dob: string; age: number } | { error: string } {
  if (!DATE_RE.test(raw)) return { error: "Please enter your child's date of birth as day, month and year." };
  const [y, m, d] = raw.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) {
    return { error: "Your child's date of birth isn't a real date. Please check it." };
  }
  if (raw > todayStr) return { error: "Your child's date of birth can't be in the future." };
  const age = ageOn(raw, todayStr);
  if (age < KID_MIN_AGE || age > KID_MAX_AGE) {
    return { error: `Children's trials are for ages ${KID_MIN_AGE} to ${KID_MAX_AGE}. Please check your child's date of birth.` };
  }
  return { dob: raw, age };
}
// 'YYYY-MM-DD' -> "12 Mar 2016" (calendar date, timezone-independent).
function fmtDob(dateStr: string): string {
  const [y, m, d] = dateStr.split("-").map(Number);
  return d + " " + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][m - 1] + " " + y;
}

// Weekday (0=Sun..6=Sat) for a 'YYYY-MM-DD' calendar date, timezone-independent.
function weekdayOf(dateStr: string): number {
  return new Date(dateStr + "T00:00:00Z").getUTCDay();
}

// Australia/Sydney's UTC offset (minutes east of UTC) at a given instant. Derived
// by formatting the instant as Sydney wall-clock and diffing from the instant —
// so DST (+10 vs +11) is handled without a timezone library.
function sydneyOffsetMinutes(ms: number): number {
  const dtf = new Intl.DateTimeFormat("en-CA", {
    timeZone: SYDNEY_TZ,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  });
  const p: Record<string, string> = {};
  dtf.formatToParts(new Date(ms)).forEach((x) => { if (x.type !== "literal") p[x.type] = x.value; });
  const asUTC = Date.UTC(
    +p.year, +p.month - 1, +p.day,
    +(p.hour === "24" ? "0" : p.hour), +p.minute, +p.second,
  );
  return Math.round((asUTC - ms) / 60000);
}

// Interpret 'YYYY-MM-DD' + 'HH:MM' as a Sydney wall-clock time → epoch ms. Start
// from the naive UTC reading, then subtract Sydney's offset at (approximately)
// that instant. The offset is stable except in the ~1h DST-transition window,
// which is immaterial to a 2-hour lead-time gate.
function sydneyWallToEpoch(dateStr: string, timeStr: string): number {
  const naive = Date.parse(dateStr + "T" + hhmm(timeStr) + ":00Z");
  const offMin = sydneyOffsetMinutes(naive);
  return naive - offMin * 60000;
}

async function verifyTurnstile(token: string, ip: string | null): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET");
  // If no secret is configured yet, fail CLOSED in production. During early
  // build you can set TURNSTILE_SECRET to the Cloudflare test secret
  // (1x0000000000000000000000000000000AA) which always passes.
  if (!secret) return false;
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", token);
  if (ip) form.append("remoteip", ip);
  try {
    const r = await fetch(
      "https://challenges.cloudflare.com/turnstile/v0/siteverify",
      { method: "POST", body: form },
    );
    const data = await r.json();
    return data.success === true;
  } catch {
    return false;
  }
}

// ---- confirmation email helpers ---------------------------------------------

const DOW = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Human class label from (type_code, audience). Mirrors public_timetable's
// type_label CASE plus trial.html's two audience-specific overrides (jmma → Kids
// MMA, alev+Kids → Teens BJJ) so the email names the class the person actually saw.
function classLabel(type: string, audience: string): string {
  if (type === "jmma") return "Kids MMA";
  if (type === "alev" && audience === "Kids") return "Teens BJJ";
  const base: Record<string, string> = {
    nogi: "No-Gi", gi: "Gi", alev: "All Levels", beg: "Beginners", adv: "Advanced",
    fund: "Fundamentals", mma: "MMA", jmma: "Junior MMA", jun: "Juniors",
    mini: "Mini Kids", omat: "Open Mat",
  };
  return base[type] || (type ? type.charAt(0).toUpperCase() + type.slice(1) : "Class");
}

// 'YYYY-MM-DD' -> "Wednesday 15 Jul" (calendar date, timezone-independent).
function fmtDayDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  return DOW[d.getUTCDay()] + " " + d.getUTCDate() + " " + MON[d.getUTCMonth()];
}

// 'HH:MM' -> "6:00 AM"
function fmt12(t: string): string {
  const [h, m] = String(t).split(":").map(Number);
  const ap = h < 12 ? "AM" : "PM";
  let hr = h % 12; if (hr === 0) hr = 12;
  return hr + ":" + String(m).padStart(2, "0") + " " + ap;
}

function escHtml(s: string): string {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// The lead's confirmation is EMAIL 1 of the trial sequence (adult or kids
// stream), built by the shared template in ../_shared/trial_emails.ts — the same
// module the trial-emails function uses for emails 2 onwards. It keeps the
// health-check button exactly as before, right after the trial details.

interface StaffNotifyData {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  howHeard: string;       // "" when the lead didn't say
  referredBy: string;     // referrer name; "" unless "Friend or family"
  preferredDay: string;   // fallback path only (no concrete slot)
  isKid: boolean;
  kidName: string;
  kidDob?: string | null;  // "12 Mar 2016 (age 7)" when given; child bookings only
  unitName: string;
  dayDate: string | null; // formatted "Wednesday 15 Jul"; null on the fallback path
  time: string | null;    // "6:00 AM"
  classLabel: string;
  friend?: string | null; // "<friend name> — invited by <booker>" when a friend also booked
  existingLead?: boolean; // true when this added a class to a lead already on the list
}

// The SECOND email — an operational heads-up to the ops inbox: who, when, which
// class, how they heard, kid-or-not. Scannable, no marketing, and NO waiver line
// (it's never signed at booking time; Patricia sees that status in the app). Same
// simple inline-styled grammar as the lead's confirmation. Pure — no I/O.
function buildStaffNotifyEmail(d: StaffNotifyData): { subject: string; html: string; text: string } {
  // An existing lead booking again is NOT a new person, and the ops inbox must
  // not read as though it is — that is the whole failure being fixed.
  const subject = (d.existingLead ? "Another trial class — " : "New trial booking — ") +
    `${d.firstName} ${d.lastName}` + (d.dayDate ? `, ${d.dayDate}` : "");

  const nameLine = d.isKid
    ? `${d.kidName} (child) — booked by ${d.firstName} ${d.lastName}`
    : `${d.firstName} ${d.lastName}`;
  const whenLine = d.dayDate
    ? `${d.dayDate}, ${d.time} — ${d.classLabel}`
    : `No fixed time — wants: ${d.preferredDay || "—"}. Call to schedule.`;

  const rows: Array<[string, string]> = [
    ["Name", nameLine],
    ...(d.isKid && d.kidDob ? [["Date of birth", d.kidDob] as [string, string]] : []),
    ["When", whenLine],
    ["Unit", d.unitName],
    ["Contact", `${d.email} · ${d.phone}`],
  ];
  if (d.howHeard) rows.push(["How they heard", d.howHeard]);
  if (d.referredBy) rows.push(["Referred by", d.referredBy]);
  // One extra row when the booker also brought a friend (a second real booking).
  if (d.friend) rows.push(["Bringing a friend", d.friend]);

  const text = ["New trial booking", "", ...rows.map(([k, v]) => `${k}: ${v}`)].join("\n");

  const htmlRows = rows.map(([k, v]) =>
    `<tr><td style="padding:5px 14px 5px 0;color:#5a6a78;font-size:13px;white-space:nowrap;vertical-align:top">${escHtml(k)}</td><td style="padding:5px 0;color:#16202b;font-size:14px">${escHtml(v)}</td></tr>`
  ).join("");
  const html = `<div style="margin:0;padding:0;background:#f5f7fa">
  <div style="max-width:560px;margin:0 auto;padding:24px 20px;font-family:Arial,Helvetica,sans-serif;color:#16202b">
    <p style="font-size:16px;font-weight:700;margin:0 0 14px">New trial booking</p>
    <table style="border-collapse:collapse;width:100%">${htmlRows}</table>
  </div>
</div>`;

  return { subject, html, text };
}

// Send an email via the Resend HTTP API. NEVER throws — email is redundancy, not
// the critical path, so every failure is logged (status + body) and swallowed. A
// dead Resend must not cost the booking. `replyTo` defaults to REPLY_TO so the lead
// email call is unchanged; the staff notify passes the LEAD's address so a reply
// reaches the person, not the shared inbox.
async function sendTrialEmail(to: string, msg: { subject: string; html: string; text: string }, replyTo: string = REPLY_TO, from: string = FROM): Promise<void> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) {
    console.error("[trial-booking] RESEND_API_KEY not set — email skipped");
    return;
  }
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        from,
        to: [to],
        reply_to: replyTo,
        subject: msg.subject,
        html: msg.html,
        text: msg.text,
      }),
    });
    if (!r.ok) {
      const body = await r.text().catch(() => "<no body>");
      console.error(`[trial-booking] Resend send failed: HTTP ${r.status} — ${body}`);
    }
  } catch (e) {
    console.error("[trial-booking] Resend send threw:", e instanceof Error ? e.message : String(e));
  }
}

// ---- handler ----------------------------------------------------------------

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405, origin);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400, origin);
  }

  // 1. Turnstile — the spam gate. Do this first so we never touch the DB for a bot.
  const token = str(payload.turnstileToken, 4000);
  const ip = req.headers.get("cf-connecting-ip") || req.headers.get("x-forwarded-for");
  const human = await verifyTurnstile(token, ip);
  if (!human) {
    return json({ error: "turnstile_failed" }, 403, origin);
  }

  // 2. Validate the lead fields (shared by both the slot path and the fallback).
  const unitId = str(payload.unit_id, 40);
  // Names are title-cased here so the roster shows "Felipe Faraone", not whatever
  // casing the person typed. Server-side on purpose — the page can't be trusted.
  const firstName = titleCase(str(payload.first_name, 80));
  const lastName = titleCase(str(payload.last_name, 80));
  const email = str(payload.email, 160).toLowerCase();
  const phone = str(payload.phone, 40);
  const howHeard = str(payload.how_heard, 200);
  // Optional referrer name — shown only when the lead picked "Friend or family".
  // Same str()/titleCase() bound as friend_name; absence is never an error.
  const referrerName = titleCase(str(payload.referrer_name, 120));
  const preferredDay = str(payload.preferred_day, 400);
  const kidName = titleCase(str(payload.kid_name, 120));
  // "Who is this trial for?" — trial.html step 4 asks this as a required answer
  // on EVERY route, including the "none of these times work" fallback. Resolved
  // below, once the class (if any) has been validated.
  const isKidClaim = boolOrNull(payload.is_kid);

  // Bring-a-friend (optional). A non-empty friend_name is the "requested" signal;
  // a stray friend_email/phone with no name is ignored (never blocks a booking).
  // friend_name holds a FULL name in one field, so it uses kid_name's 120 bound
  // (the single first/last fields are 80 each). Email/phone match the lead bounds.
  const friendName = titleCase(str(payload.friend_name, 120));
  const friendEmail = str(payload.friend_email, 160).toLowerCase();
  const friendPhone = str(payload.friend_phone, 40);
  // The friend can be a CHILD of the person filling the form (a parent bringing
  // a second child). Then the booking is exactly a child booking: the booker is
  // the person filling the form (first/last name, email, phone above), and the
  // child is friend_kid_name / friend_kid_dob. friend_name/email/phone are not
  // used. Absent friend_is_kid (an older trial.html) = an adult friend, as before.
  const friendIsKid = boolOrNull(payload.friend_is_kid) === true;
  const friendKidName = titleCase(str(payload.friend_kid_name, 120));

  if (!UUID_RE.test(unitId)) return bad("Please choose which academy.", origin);
  if (!firstName) return bad("Please enter your first name.", origin);
  if (!lastName) return bad("Please enter your last name.", origin);
  if (!EMAIL_RE.test(email)) return bad("Please enter a valid email address.", origin);
  if (!phone) return bad("Please enter a phone number.", origin);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Unit must exist and be active. This resolves the uuid we insert AND lets the
  // class check below confirm the picked class actually belongs to this unit.
  const { data: unitRow, error: unitErr } = await supabase
    .from("units")
    .select("id, name, address, city, phone")
    .eq("id", unitId)
    .eq("active", true)
    .maybeSingle();
  if (unitErr || !unitRow) return bad("That academy isn't available. Please pick another.", origin);

  // ---- CLASS VALIDATION BLOCK ------------------------------------------------
  // Everything the client sent about the class is re-derived from the DB here.
  // NEVER trust the client: not the unit link, not the weekday, not the time,
  // not whether it's a kids class.
  const classId = str(payload.class_id, 40);
  const classDate = str(payload.class_date, 10);
  const clientTime = hhmm(str(payload.class_time, 8));

  let isKid = false;
  // The chosen class's audience, kept as EVIDENCE for the resolution below —
  // it no longer decides is_kid by itself.
  let classAudience = "";
  let insertClassId: string | null = null;
  let insertClassDate: string | null = null;
  let insertClassTime: string | null = null;
  let emailClassLabel = "Trial class"; // display label for the confirmation email

  if (classId) {
    // A concrete slot was picked — validate it against the live timetable.
    if (!UUID_RE.test(classId)) return bad("That class could not be found. Please pick another time.", origin);
    if (!DATE_RE.test(classDate)) return bad("That date is invalid. Please pick another time.", origin);

    const { data: cls, error: clsErr } = await supabase
      .from("classes")
      .select("id, unit_id, day_of_week, time, active, audience, type, duration_minutes")
      .eq("id", classId)
      .maybeSingle();

    if (clsErr || !cls) return bad("That class could not be found. Please pick another time.", origin);
    if (cls.active !== true) return bad("That class is no longer running. Please pick another time.", origin);
    if (cls.unit_id !== unitRow.id) return bad("That class isn't at the academy you chose.", origin);
    if (weekdayOf(classDate) !== cls.day_of_week) return bad("That day doesn't match the class. Please pick another time.", origin);
    if (hhmm(String(cls.time)) !== clientTime) return bad("That time is no longer on the schedule. Please pick another time.", origin);

    // Only the six advertised trial entry points are bookable — reject anything
    // else (adv/gi/fund/jmma/omat/…) even if a tampered client sent its class_id.
    if (!TRIAL_TYPE_CODES.has(String(cls.type))) {
      return bad("That class isn't available for a free trial. Please pick another.", origin);
    }

    // Date must sit inside [today, today + horizon] in Sydney.
    const todayStr = sydneyTodayStr();
    const maxStr = new Date(new Date(todayStr + "T00:00:00Z").getTime() + BOOKING_HORIZON_DAYS * 86400000)
      .toISOString().slice(0, 10);
    if (classDate < todayStr || classDate > maxStr) {
      return bad("Please pick a time within the next week.", origin);
    }

    // Reject only if the class has ALREADY ENDED (start + duration ≤ now), not if
    // it merely starts soon. Mirrors trial.html's end-time slot filter so a class
    // in progress — e.g. someone arriving a few minutes late — is still bookable;
    // enforced here too because the client grid is only an affordance. Fallback of
    // 60 min when duration_minutes is missing/zero.
    const startEpoch = sydneyWallToEpoch(classDate, String(cls.time));
    const durationMs = (Number(cls.duration_minutes) || 60) * 60 * 1000;
    if (startEpoch + durationMs <= Date.now()) {
      return bad("That class has already finished. Please pick a later class.", origin);
    }

    // WAS: `isKid = cls.audience === "Kids"` — is_kid derived from the class and
    // never taken from the client. That was the right rule while nothing asked:
    // a public endpoint should not trust a flag it never collected. The form now
    // collects it as a required answer, so the client is no longer guessing —
    // it is reporting what the parent said. Resolved after this block.
    classAudience = String(cls.audience || "");

    insertClassId = cls.id;
    insertClassDate = classDate;
    insertClassTime = hhmm(String(cls.time)); // canonical DB value, not the client's
    emailClassLabel = classLabel(String(cls.type), String(cls.audience));
  } else {
    // Fallback path ("None of these times work") — we only have free-text
    // availability. is_kid stays false (no class → no derived audience).
    if (!preferredDay) return bad("Please tell us when you're usually free.", origin);
  }

  // 2c. WHO IS THIS FOR — the answer decides, with one evidence-backed fallback.
  //
  // ABSENT OR MALFORMED (isKidClaim === null) splits on whether we have any
  // evidence at all, because the two cases are not the same risk:
  //   a class WAS picked  -> fall back to the class's audience. That is the old
  //     behaviour and it is evidence from OUR database, not a guess. It keeps a
  //     browser still running the pre-question trial.html booking successfully
  //     (that page has no service worker, but an already-open tab holds the old
  //     JS), and for a Kids class it is also correct.
  //   NO class was picked -> refuse. The fallback path has nothing to derive
  //     from, so defaulting is pure invention, and inventing `false` here is
  //     precisely what wrote 17 children-or-adults into one bucket. Better a
  //     retryable 400 than another silent adult. A reload picks up the new form
  //     immediately, since trial.html is not service-worker cached.
  if (isKidClaim === null) {
    if (!insertClassId) {
      return bad("Please tell us whether this trial is for an adult or a child, then try again.", origin);
    }
    isKid = classAudience === "Kids";
  } else {
    isKid = isKidClaim;
  }

  // kid_name follows the ANSWER, not the class — so the fallback path asks for
  // it too, which it never did before.
  if (isKid && !kidName) return bad("Please add your child's name.", origin);

  // Child's date of birth (migration 136). Read ONLY for a child booking; ignored
  // otherwise. OPTIONAL here on purpose: a trial.html still open from before the
  // field existed must keep booking during the rollout — trial.html is what makes
  // it required. When present it must be valid, checked before anything is written.
  let kidDob: string | null = null;
  let kidAge: number | null = null;
  if (isKid) {
    const rawDob = str(payload.kid_dob, 10);
    if (rawDob) {
      const chk = checkKidDob(rawDob, sydneyTodayStr());
      if ("error" in chk) return bad(chk.error, origin);
      kidDob = chk.dob;
      kidAge = chk.age;
    }
  }

  // A child in an Adults class is STORABLE, never rejected: the academy puts
  // teenagers in adult classes deliberately (14 and over train with adults), so
  // this combination is frequently correct. Logged, not blocked — and the ops
  // email already renders "(child)" off isKid, so the booking arrives labelled.
  if (insertClassId && classAudience && isKid !== (classAudience === "Kids")) {
    console.log(
      `[trial-booking] answer/class mismatch — is_kid=${isKid}, class audience=${classAudience}; storing the answer`,
    );
  }

  // 2b. Friend block applies ONLY to a concrete slot (insertClassId) — a friend
  // needs a real session to attend, so it is ignored entirely on the fallback
  // ("None of these times work") path. Validate up-front so an invalid friend
  // block rejects the request BEFORE anything is inserted (nothing half-written).
  const friendActive = insertClassId !== null && (friendIsKid || friendName.length > 0);
  let friendKidDob: string | null = null;
  let friendKidAge: number | null = null;
  if (friendActive && friendIsKid) {
    // A child friend is validated like a child booking: name, and a date of
    // birth that is real, not in the future, and aged 2 to 17.
    if (!friendKidName) return bad("Please add the name of the child you're bringing.", origin);
    if (isKid && friendKidName === kidName) {
      return bad("You've added the same child twice. Remove the second one, or enter your other child's name.", origin);
    }
    const rawFriendDob = str(payload.friend_kid_dob, 10);
    if (!rawFriendDob) return bad("Please add the date of birth of the child you're bringing.", origin);
    const fchk = checkKidDob(rawFriendDob, sydneyTodayStr());
    if ("error" in fchk) return bad("For the child you're bringing: " + fchk.error, origin);
    friendKidDob = fchk.dob;
    friendKidAge = fchk.age;
    // Same rule as the booker's own child: an Adults class is stored, never
    // rejected (teenagers train with adults), logged here and labelled "(child)"
    // in the ops email.
    if (classAudience !== "Kids") {
      console.log(
        `[trial-booking] friend answer/class mismatch — friend is_kid=true, class audience=${classAudience}; storing the answer`,
      );
    }
  } else if (friendActive) {
    if (!friendEmail && !friendPhone) return bad("Add your friend's email or phone, or remove their name.", origin);
    if (friendEmail && !EMAIL_RE.test(friendEmail)) return bad("Please enter a valid email for your friend.", origin);
    // No Australian phone validator exists in this function (it lives only in
    // trial.html); friend_phone is accepted as sent — the SAME shallow rule the
    // primary phone gets here (presence only). Noted in the report.
  }

  // 2d. ALREADY A LEAD? -------------------------------------------------------
  // Every submission used to insert a row, so a person who booked, missed the
  // class and booked again became TWO leads — one no_show, one booked, the phone
  // in two formats, and the owner working that list saw two people. They were not
  // making a second booking; they thought they were rebooking.
  //
  // public.trial_sessions already models one lead with N occurrences, and
  // trialClasses (index.html:3459) already reads it. Nothing wrote sessions from
  // the public form. This does.
  //
  // MATCH RULE — all of these, or it is a different lead:
  //   unit_id      same academy. Trialling at both units is genuinely two leads.
  //   email        equality on the value this function already normalised at the
  //                top (str() trims, .toLowerCase()). eq() not ilike(): every row
  //                this endpoint writes is already lowercased, and ilike would
  //                give % and _ in an address wildcard meaning.
  //   is_kid       a parent's own trial and their child's are different
  //                PARTICIPANTS that share an inbox.
  //   kid_name     for kids, same again — one email, two children, two leads.
  //   NOT converted. They are a member; a fresh enquiry is a fresh thing.
  const nowISO = new Date().toISOString();
  // A lapse is the office saying "this one went cold", not that the person
  // stopped existing. Coming back inside a quarter is the same conversation and
  // should keep its contact log and waiver; coming back after one is a new
  // approach, and resurrecting a long-dead row would also quietly corrupt what
  // "lapsed" measures. Age is taken from lapsed_at, falling back to booked_at
  // when it is missing, because on ambiguity the duplicate is the worse outcome.
  const RETURNING_LEAD_DAYS = 90;
  type LeadRow = {
    id: string; waiver_token: string | null; trial_status: string;
    class_id: string | null; class_date: string | null; class_time: string | null;
    phone: string | null; lapsed_at: string | null; booked_at: string | null;
    kid_name: string | null;
    kid_dob: string | null;
  };
  // THE DEDUPE RULE as three steps, used for the booking itself AND for a child
  // brought along as the "friend" (a parent's second child), so the same parent
  // with two children is two leads, and a child already on the list is found.

  // The usable existing lead for (unit, this email, is_kid, kid name), or null.
  // Never fails a booking: a lookup error means "none" (insert, as before).
  async function findLead(forKid: boolean, forKidName: string): Promise<LeadRow | null> {
    const { data: leadRows, error: leadErr } = await supabase
      .from("trial_bookings")
      .select("id, waiver_token, trial_status, class_id, class_date, class_time, phone, lapsed_at, booked_at, kid_name, kid_dob")
      .eq("unit_id", unitRow.id)
      .eq("email", email)
      .eq("is_kid", forKid)
      .neq("trial_status", "converted")
      .order("booked_at", { ascending: false })
      .limit(10);
    if (leadErr) {
      // Never fail a booking over the dedupe lookup — fall through and insert,
      // which is exactly today's behaviour.
      console.error("[trial-booking] lead lookup error:", leadErr.message);
      return null;
    }
    const usable = (leadRows || []).filter((r) => {
      if (forKid && titleCase(String(r.kid_name || "")) !== forKidName) return false;
      if (r.trial_status === "lapsed") {
        const ref = r.lapsed_at || r.booked_at;
        if (!ref) return true;
        const age = Date.now() - new Date(String(ref)).getTime();
        if (age > RETURNING_LEAD_DAYS * 86400000) return false;
      }
      return true;
    });
    return (usable[0] as LeadRow) || null;
  }

  // Add this class to an existing lead. "dup" when they are already booked into
  // this exact occurrence, "error" when a write failed, else "ok".
  async function attachSession(lead: LeadRow): Promise<"ok" | "dup" | "error"> {
    const { data: sessRows, error: sessErr } = await supabase
      .from("trial_sessions")
      .select("id, class_id, class_date")
      .eq("trial_booking_id", lead.id);
    if (sessErr) {
      console.error("[trial-booking] session read error:", sessErr.message);
      return "error";
    }
    const sessions = sessRows || [];

    // ALREADY BOOKED INTO THIS EXACT OCCURRENCE. Say so — a submission that
    // silently does nothing is worse than one that explains itself. Checked
    // against sessions AND, when there are none, the legacy trio, because that
    // trio IS their current booking.
    const dupSession = sessions.some((s) =>
      String(s.class_id) === insertClassId && String(s.class_date) === insertClassDate
    );
    const dupLegacy = sessions.length === 0 &&
      lead.class_id === insertClassId && lead.class_date === insertClassDate;
    if (dupSession || dupLegacy) return "dup";

    // LEGACY TRIO BACKFILL, and the reason this is not optional. trialClasses
    // reads sessions the moment ANY exist and only falls back to
    // trial_bookings.class_id/date/time when there are none. So attaching the
    // first session to a lead that still carries the trio would make their
    // ORIGINAL booking vanish from the card and the mat. Materialise the trio
    // as a session first. Same move _doAddTrialSession makes (index.html:11972),
    // including carrying attendance across from the scalar status.
    if (sessions.length === 0 && lead.class_id && lead.class_date) {
      const { error: backErr } = await supabase.from("trial_sessions").insert({
        trial_booking_id: lead.id,
        class_id: lead.class_id,
        class_date: lead.class_date,
        class_time: lead.class_time,
        attended: lead.trial_status === "attended",
      });
      if (backErr) {
        console.error("[trial-booking] legacy backfill error:", backErr.message);
        return "error";
      }
    }

    const { error: newSessErr } = await supabase.from("trial_sessions").insert({
      trial_booking_id: lead.id,
      class_id: insertClassId,
      class_date: insertClassDate,
      class_time: insertClassTime,
      attended: false,
    });
    if (newSessErr) {
      console.error("[trial-booking] session insert error:", newSessErr.message);
      return "error";
    }
    return "ok";
  }

  // The lead row itself. Deliberately NOT a general overwrite.
  async function patchLead(lead: LeadRow, leadKidDob: string | null, leadPreferredDay: string): Promise<void> {
    const patch: Record<string, unknown> = {};
    // no_show / lapsed describe a PAST class. The person now has a live upcoming
    // one, and the card gates Convert on that scalar (index.html:11569), so
    // leaving it stale recreates the "cannot convert a no_show" dead end by hand.
    // lapsed_at is cleared with it — it timestamps an event that no longer
    // stands. The missed class is not erased: it survives as its own session row
    // with attended=false, which is a better place for a per-class fact than a
    // row-level scalar. 'attended' is left alone — it is still true, and it does
    // not block anything.
    if (lead.trial_status === "no_show" || lead.trial_status === "lapsed") {
      patch.trial_status = "booked";
      patch.lapsed_at = null;
    }
    // DETAILS: fill gaps, never overwrite. The owner curates this list by hand,
    // and a resubmission is not evidence the older value was wrong — the reported
    // pair differed only in phone FORMAT, which is not new information. A blank
    // field has nothing to protect, so it gets filled. Anything genuinely new
    // still reaches the office in the staff email below, which carries what was
    // submitted this time.
    if (!lead.phone && phone) patch.phone = phone;
    // Child's date of birth: same fill-a-gap rule — set when the lead has none,
    // never overwrite a stored one (migration 136).
    if (leadKidDob && !lead.kid_dob) patch.kid_dob = leadKidDob;
    // The exception: availability on the fallback path. preferredDay is only
    // non-empty when no class was chosen, and it is a statement about the future
    // that supersedes the old one rather than competing with it.
    if (leadPreferredDay) patch.preferred_day = leadPreferredDay;
    if (Object.keys(patch).length) {
      const { error: updErr } = await supabase.from("trial_bookings").update(patch).eq("id", lead.id);
      if (updErr) console.error("[trial-booking] lead update error:", updErr.message);
    }
  }

  const existingLead: LeadRow | null = await findLead(isKid, kidName);

  // The id and token the rest of this function works from, whichever branch ran.
  let bookingId: string;
  let bookingToken: string | null;

  if (existingLead) {
    if (insertClassId) {
      const attached = await attachSession(existingLead);
      if (attached === "dup") {
        return bad("You're already booked into that class. Check your email for the details, or pick a different time.", origin);
      }
      if (attached === "error") {
        return json({ ok: false, error: "Something went wrong saving your booking. Please try again." }, 500, origin);
      }
    }

    await patchLead(existingLead, isKid ? kidDob : null, preferredDay);

    console.log(
      `[trial-booking] existing lead ${existingLead.id} (${existingLead.trial_status}) — ` +
      (insertClassId ? "session added" : "availability updated") + ", no duplicate row created",
    );
    bookingId = existingLead.id;
    bookingToken = existingLead.waiver_token;
  } else {

  // 3. Insert with the service role.
  const { data: inserted, error: insErr } = await supabase
    .from("trial_bookings")
    .insert({
      unit_id: unitRow.id,
      first_name: firstName,
      last_name: lastName,
      email,
      phone,
      how_heard: howHeard || null,
      preferred_day: preferredDay || null,
      is_kid: isKid,
      kid_name: isKid ? kidName : null,
      kid_dob: isKid ? kidDob : null,
      class_id: insertClassId,
      class_date: insertClassDate,
      class_time: insertClassTime,
      trial_status: "booked",
      booked_at: nowISO,
    })
    .select("id, waiver_token")
    .single();

  if (insErr || !inserted) {
    console.error("[trial-booking] insert error:", insErr?.message);
    return json({ ok: false, error: "Something went wrong saving your booking. Please try again." }, 500, origin);
  }
    bookingId = inserted.id;
    bookingToken = inserted.waiver_token;
  }

  // 4. Confirmation email — redundancy, NOT the critical path. The booking is
  //    already saved and the on-screen CTA works; sendTrialEmail never throws, so
  //    a dead Resend is logged and swallowed and we STILL return ok:true below.
  //    Build the waiver link EXACTLY as trial.html does (same t / k / n params) so
  //    the emailed link and the on-screen CTA are identical.
  const participant = isKid ? kidName : firstName;
  let waiverLink = `${WAIVER_ORIGIN}/waiver.html?t=${encodeURIComponent(String(bookingToken || ""))}`;
  if (isKid) waiverLink += "&k=1";
  if (participant) waiverLink += `&n=${encodeURIComponent(participant)}`;

  // The unit's address line: the address as stored, trimmed, no city appended
  // (_shared/unit_address.ts). The shared template builds the Maps link from it,
  // the same query trial.html's step 5 uses.
  const addressLine = unitAddressLine(unitRow.address);
  // EMAIL 1 of the trial sequence: kids stream (to the parent, about the child)
  // or adult stream. The unsubscribe footer is left off only when
  // EMAIL_UNSUB_SECRET is missing: a confirmation is never held back for it.
  const msg = renderTrialEmail("1", isKid ? "kids" : "adult", {
    firstName,
    childFirstName: isKid ? (kidName.split(/\s+/)[0] || "") : "",
    location: unitRow.name,
    className: insertClassDate ? emailClassLabel : null,
    trialDate: insertClassDate ? fmtDayDate(insertClassDate) : null,
    trialTime: insertClassTime ? fmt12(insertClassTime) : null,
    addressLine,
    unitLegacyId: null,      // email 1 has no booking button
    unitPhone: unitRow.phone || null,
    waiverLink,
    unsubscribeUrl: await trialUnsubUrl(Deno.env.get("EMAIL_UNSUB_SECRET"), email),
  });
  // Awaited so the edge runtime doesn't tear down the isolate mid-send.
  await sendTrialEmail(email, msg, REPLY_TO, TRIAL_FROM);

  // ---- Bring a friend: a SECOND real booking (own row, own waiver_token). ----
  // FAILURE-ISOLATED: unreachable unless the primary already returned `inserted`
  // (a 500 above short-circuits otherwise), and any friend error is logged and
  // swallowed — the primary booking stays saved and the response stays ok:true.
  // Never rolls back, never fails the request.
  let friendOk = false;
  let friendStaffLine: string | null = null;
  if (friendActive && friendIsKid) {
    // A CHILD friend (the booker's other child) is a child booking: the booker is
    // the person filling the form (name, email, phone), is_kid true, kid_name and
    // kid_dob. Same dedupe rule as the booking itself — unit, email, is_kid and
    // kid name — so two children of one parent are two leads, and a child who is
    // already on the list gets this class added instead of a second row.
    let friendToken: string | null = null;
    let friendNote = "";
    let friendAlreadyBooked = false;
    const friendLead = await findLead(true, friendKidName);
    if (friendLead) {
      const attached = await attachSession(friendLead);
      if (attached === "error") {
        console.error("[trial-booking] friend (child) session error for lead", friendLead.id);
      } else {
        if (attached === "ok") await patchLead(friendLead, friendKidDob, "");
        friendOk = true;
        friendToken = friendLead.waiver_token;
        friendAlreadyBooked = attached === "dup";
        friendNote = friendAlreadyBooked ? " (already booked into this class)" : " (added to their existing trial)";
      }
    } else {
      const { data: friendRow, error: friendErr } = await supabase
        .from("trial_bookings")
        .insert({
          unit_id: unitRow.id,
          first_name: firstName,
          last_name: lastName,
          email,
          phone,
          how_heard: "Friend or family",
          preferred_day: null,
          is_kid: true,
          kid_name: friendKidName,
          kid_dob: friendKidDob,
          class_id: insertClassId,
          class_date: insertClassDate,
          class_time: insertClassTime,
          trial_status: "booked",
          booked_at: nowISO,
          invited_by_booking_id: bookingId,
        })
        .select("id, waiver_token")
        .single();
      if (friendErr || !friendRow) {
        console.error("[trial-booking] friend (child) insert error:", friendErr?.message);
      } else {
        friendOk = true;
        friendToken = friendRow.waiver_token;
      }
    }
    if (friendOk) {
      friendStaffLine = `${friendKidName} (child${friendKidDob ? `, born ${fmtDob(friendKidDob)}, age ${friendKidAge}` : ""})` +
        ` — booked by ${firstName} ${lastName}${friendNote}`;
      // Email 1, KIDS stream, to the booker — with this child's OWN waiver link
      // (k=1 and the child's name, exactly like a child booking). Not re-sent when
      // the child was already booked into this very class.
      if (!friendAlreadyBooked) {
        let friendWaiverLink = `${WAIVER_ORIGIN}/waiver.html?t=${encodeURIComponent(String(friendToken || ""))}&k=1`;
        if (friendKidName) friendWaiverLink += `&n=${encodeURIComponent(friendKidName)}`;
        const friendMsg = renderTrialEmail("1", "kids", {
          firstName,
          childFirstName: friendKidName.split(/\s+/)[0] || "",
          location: unitRow.name,
          className: insertClassDate ? emailClassLabel : null,
          trialDate: insertClassDate ? fmtDayDate(insertClassDate) : null,
          trialTime: insertClassTime ? fmt12(insertClassTime) : null,
          addressLine,
          unitLegacyId: null,      // email 1 has no booking button
          unitPhone: unitRow.phone || null,
          waiverLink: friendWaiverLink,
          unsubscribeUrl: await trialUnsubUrl(Deno.env.get("EMAIL_UNSUB_SECRET"), email),
        });
        await sendTrialEmail(email, friendMsg, REPLY_TO, TRIAL_FROM);
      }
    }
  } else if (friendActive) {
    // Split friend_name on the FIRST space: before → first, after → last. No space
    // → whole name is the first, last EMPTY (never invent a surname — same rule the
    // trial→student convert flow uses).
    const _sp = friendName.indexOf(" ");
    const friendFirst = _sp >= 0 ? friendName.slice(0, _sp) : friendName;
    const friendLast = _sp >= 0 ? friendName.slice(_sp + 1).trim() : "";
    const { data: friendRow, error: friendErr } = await supabase
      .from("trial_bookings")
      .insert({
        unit_id: unitRow.id,
        first_name: friendFirst,
        last_name: friendLast,
        email: friendEmail || null,
        phone: friendPhone || null,
        how_heard: "Friend or family",
        preferred_day: null,
        is_kid: false,
        kid_name: null,
        class_id: insertClassId,
        class_date: insertClassDate,
        class_time: insertClassTime,
        trial_status: "booked",
        booked_at: nowISO,
        invited_by_booking_id: bookingId,
      })
      .select("id, waiver_token")
      .single();
    if (friendErr || !friendRow) {
      console.error("[trial-booking] friend insert error:", friendErr?.message);
    } else {
      friendOk = true;
      friendStaffLine = `${friendFirst}${friendLast ? " " + friendLast : ""} — invited by ${firstName} ${lastName}`;
      // Friend confirmation email — only when they gave an email. Email 1
      // (adult stream) with the friend's OWN waiver token; no k=1 (a friend is
      // booked as an adult, is_kid:false).
      if (friendEmail) {
        let friendWaiverLink = `${WAIVER_ORIGIN}/waiver.html?t=${encodeURIComponent(String(friendRow.waiver_token || ""))}`;
        if (friendFirst) friendWaiverLink += `&n=${encodeURIComponent(friendFirst)}`;
        const friendMsg = renderTrialEmail("1", "adult", {
          firstName: friendFirst,
          childFirstName: "",
          location: unitRow.name,
          className: insertClassDate ? emailClassLabel : null,
          trialDate: insertClassDate ? fmtDayDate(insertClassDate) : null,
          trialTime: insertClassTime ? fmt12(insertClassTime) : null,
          addressLine,
          unitLegacyId: null,      // email 1 has no booking button
          unitPhone: unitRow.phone || null,
          waiverLink: friendWaiverLink,
          unsubscribeUrl: await trialUnsubUrl(Deno.env.get("EMAIL_UNSUB_SECRET"), friendEmail),
        });
        await sendTrialEmail(friendEmail, friendMsg, REPLY_TO, TRIAL_FROM);
      }
    }
  }

  // SECOND email — operational heads-up to the ops inbox, from the SAME booking
  // data. reply_to is the LEAD's email so Patricia can reply straight to them.
  // Also redundancy: sendTrialEmail never throws, so a failure still returns ok:true.
  const staffMsg = buildStaffNotifyEmail({
    firstName,
    lastName,
    email,
    phone,
    howHeard,
    referredBy: referrerName,
    preferredDay,
    isKid,
    kidName,
    kidDob: kidDob ? `${fmtDob(kidDob)} (age ${kidAge})` : null,
    unitName: unitRow.name,
    dayDate: insertClassDate ? fmtDayDate(insertClassDate) : null,
    time: insertClassTime ? fmt12(insertClassTime) : null,
    classLabel: emailClassLabel,
    friend: friendStaffLine, // one extra row when a friend also booked; null otherwise
    existingLead: !!existingLead,
  });
  await sendTrialEmail(STAFF_NOTIFY_TO, staffMsg, email);

  // friend_ok is present ONLY when a friend was actually requested — so the page
  // can tell "no friend" (key absent → say nothing) apart from "friend failed"
  // (friend_ok:false → warn them). Omitted entirely on the no-friend path.
  const resBody: Record<string, unknown> = { ok: true, waiver_token: bookingToken };
  if (friendActive) resBody.friend_ok = friendOk;
  return json(resBody, 200, origin);
});
