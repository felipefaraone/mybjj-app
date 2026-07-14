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

// ---- config -----------------------------------------------------------------

// Origins allowed to call this function (the booking page + local testing).
// Tighten/extend as needed.
const ALLOWED_ORIGINS = [
  "https://mybjj-app.com",
  "https://www.mybjj-app.com",
];

// The visitor can be no more than this many days ahead. The page projects the
// live weekly grid onto the next 7 days; we allow 8 (one day of slack) so a
// timezone edge never rejects a legitimate booking. Computed in Australia/Sydney.
const BOOKING_HORIZON_DAYS = 8;
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

// No slot may be booked within this window of "now" (Australia/Sydney) — a class
// starting in a few minutes helps nobody and the front desk cannot prepare.
const LEAD_TIME_MS = 2 * 60 * 60 * 1000; // 2 hours

// ---- confirmation email (Resend) --------------------------------------------
// Sender identity for the trial confirmation email. Kept as named constants so a
// domain / address change is a one-line edit. `mybjj-app.com` is the verified
// Resend domain; replies must land in the academy's real inbox, not a black hole.
const FROM = "myBJJ <noreply@mybjj-app.com>";
const REPLY_TO = "info@mybjj.com.au";
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

interface EmailData {
  firstName: string;
  classLabel: string;
  unitName: string;
  dayDate: string | null;   // "Wednesday 15 Jul", null on the flexible-time fallback
  time: string | null;      // "6:00 AM"
  address: string | null;   // full street line, null when the unit has none
  mapsUrl: string | null;   // Google Maps link for the address, null when no address
  phone: string | null;
  waiverLink: string;
}

// Build the plain confirmation email (subject + html + text). Pure — no I/O.
function buildTrialEmail(d: EmailData): { subject: string; html: string; text: string } {
  const unitFull = "myBJJ " + d.unitName;
  const subject = d.dayDate
    ? `You're booked — ${d.classLabel} at ${unitFull}, ${d.dayDate}`
    : `You're booked at ${unitFull} — complete your health check`;

  // Session block lines — the address is handled separately (it becomes a Maps
  // link / gets its own URL line), so it is NOT in this shared list.
  const sessionLines: string[] = [];
  if (d.dayDate && d.time) sessionLines.push(`${d.dayDate}, ${d.time}`);
  sessionLines.push(`${d.classLabel} · ${unitFull}`);
  if (!d.dayDate) sessionLines.push("We'll confirm your class time with you shortly.");

  const signoff = d.phone ? `${unitFull} · ${d.phone}` : unitFull;
  const trialUrl = `${WAIVER_ORIGIN}/trial.html`;

  // ---- text ----
  // Address (when present) prints as the line itself + the Maps URL on its own
  // line below. No address → neither line, never a blank one.
  const text = [
    `Hi ${d.firstName},`,
    ``,
    `You're booked in. Here are the details:`,
    ``,
    ...sessionLines,
    ...(d.address ? [d.address, d.mapsUrl!] : []),
    ``,
    `Complete your health check — it takes about three minutes, and it must be done before you train:`,
    d.waiverLink,
    ``,
    `Before you arrive:`,
    `- Arrive 10 minutes early so we can show you around.`,
    `- Wear a t-shirt and shorts. No jewellery.`,
    `- We'll lend you everything else — you don't need to buy anything.`,
    ``,
    `Bring a friend — their first class is free too.`,
    `Send them here: ${trialUrl}`,
    ``,
    `See you on the mats,`,
    signoff,
    `You can just reply to this email if you need anything.`,
  ].join("\n");

  // ---- html (simple, inline-styled; no external CSS / fonts / images) ----
  const sessionHtml = sessionLines
    .map((l, i) => `<div style="font-size:${i === 0 && d.dayDate ? "18px;font-weight:700" : "15px"};color:#16202b;line-height:1.5">${escHtml(l)}</div>`)
    .join("");
  // Address as a real Google Maps link (omitted entirely when there is no address).
  const addrHtml = d.address
    ? `<div style="font-size:15px;line-height:1.5;margin-top:2px"><a href="${escHtml(d.mapsUrl!)}" style="color:#1A5DAD;text-decoration:underline">${escHtml(d.address)}</a></div>`
    : "";

  const html = `<div style="margin:0;padding:0;background:#f5f7fa">
  <div style="max-width:560px;margin:0 auto;padding:24px 20px;font-family:Arial,Helvetica,sans-serif;color:#16202b">
    <p style="font-size:16px;margin:0 0 16px">Hi ${escHtml(d.firstName)}, you're booked in.</p>
    <div style="background:#ffffff;border:1px solid #e1e7ee;border-radius:10px;padding:16px 18px;margin:0 0 22px">
      ${sessionHtml}${addrHtml}
    </div>
    <a href="${escHtml(d.waiverLink)}" style="display:block;background:#1A5DAD;color:#ffffff;text-decoration:none;text-align:center;font-size:17px;font-weight:700;padding:15px 20px;border-radius:10px">Complete your health check</a>
    <p style="font-size:13.5px;color:#5a6a78;margin:10px 0 24px;text-align:center">It takes about three minutes, and it must be done before you train.</p>
    <p style="font-size:15px;font-weight:700;color:#16202b;margin:0 0 6px">Before you arrive</p>
    <p style="font-size:14.5px;color:#5a6a78;line-height:1.7;margin:0 0 22px">
      Arrive 10 minutes early so we can show you around.<br>
      Wear a t-shirt and shorts. No jewellery.<br>
      We'll lend you everything else — you don't need to buy anything.
    </p>
    <p style="font-size:14.5px;color:#16202b;margin:0 0 22px">Bring a friend — their first class is free too.<br>Send them here: <a href="${escHtml(trialUrl)}" style="color:#1A5DAD;text-decoration:underline">${escHtml(trialUrl)}</a></p>
    <p style="font-size:14px;color:#5a6a78;line-height:1.6;margin:0;border-top:1px solid #e1e7ee;padding-top:16px">
      See you on the mats,<br>
      <strong style="color:#16202b">${escHtml(signoff)}</strong><br>
      You can just reply to this email if you need anything.
    </p>
  </div>
</div>`;

  return { subject, html, text };
}

// Send the confirmation email via the Resend HTTP API. NEVER throws — the email
// is redundancy, not the critical path, so every failure is logged (status + body)
// and swallowed. A dead Resend must not cost the booking.
async function sendTrialEmail(to: string, msg: { subject: string; html: string; text: string }): Promise<void> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) {
    console.error("[trial-booking] RESEND_API_KEY not set — confirmation email skipped");
    return;
  }
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: REPLY_TO,
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
  const preferredDay = str(payload.preferred_day, 400);
  const kidName = titleCase(str(payload.kid_name, 120));

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
      .select("id, unit_id, day_of_week, time, active, audience, type")
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

    // 2-hour lead time: the booked start (Sydney wall-clock) must be at least 2h
    // out. Mirrors trial.html's LEAD_MIN filter; enforced here because the client
    // grid is only an affordance.
    if (sydneyWallToEpoch(classDate, String(cls.time)) - Date.now() < LEAD_TIME_MS) {
      return bad("That class starts too soon to book. Please pick a later time.", origin);
    }

    // is_kid is DERIVED from the class, never taken from the client.
    isKid = cls.audience === "Kids";
    if (isKid && !kidName) return bad("Please add your child's name.", origin);

    insertClassId = cls.id;
    insertClassDate = classDate;
    insertClassTime = hhmm(String(cls.time)); // canonical DB value, not the client's
    emailClassLabel = classLabel(String(cls.type), String(cls.audience));
  } else {
    // Fallback path ("None of these times work") — we only have free-text
    // availability. is_kid stays false (no class → no derived audience).
    if (!preferredDay) return bad("Please tell us when you're usually free.", origin);
  }

  // 3. Insert with the service role.
  const nowISO = new Date().toISOString();
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

  // 4. Confirmation email — redundancy, NOT the critical path. The booking is
  //    already saved and the on-screen CTA works; sendTrialEmail never throws, so
  //    a dead Resend is logged and swallowed and we STILL return ok:true below.
  //    Build the waiver link EXACTLY as trial.html does (same t / k / n params) so
  //    the emailed link and the on-screen CTA are identical.
  const participant = isKid ? kidName : firstName;
  let waiverLink = `${WAIVER_ORIGIN}/waiver.html?t=${encodeURIComponent(String(inserted.waiver_token || ""))}`;
  if (isKid) waiverLink += "&k=1";
  if (participant) waiverLink += `&n=${encodeURIComponent(participant)}`;

  const addressLine = unitRow.address
    ? unitRow.address + (unitRow.city ? ", " + unitRow.city : "")
    : null;
  // Same Google Maps link the step-5 screen builds — query is the full address line.
  const mapsUrl = addressLine
    ? "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(addressLine)
    : null;
  const msg = buildTrialEmail({
    firstName,
    classLabel: emailClassLabel,
    unitName: unitRow.name,
    dayDate: insertClassDate ? fmtDayDate(insertClassDate) : null,
    time: insertClassTime ? fmt12(insertClassTime) : null,
    address: addressLine,
    mapsUrl,
    phone: unitRow.phone || null,
    waiverLink,
  });
  // Awaited so the edge runtime doesn't tear down the isolate mid-send.
  await sendTrialEmail(email, msg);

  return json({ ok: true, waiver_token: inserted.waiver_token }, 200, origin);
});
