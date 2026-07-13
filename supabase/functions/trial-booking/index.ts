// supabase/functions/trial-booking/index.ts
//
// Public trial-booking endpoint. This is the ONLY write path for the public
// booking form (mybjj-app.com/trial.html). It:
//   1. validates the Cloudflare Turnstile token server-side (the real spam gate),
//   2. validates the payload,
//   3. if a concrete class was picked, RE-VALIDATES it against the live timetable
//      (the client is never trusted — see the class validation block below),
//   4. inserts into public.trial_bookings with the service role (trial_status='booked'),
//   5. returns the row's waiver_token so the page can hand off to /waiver.html?t=...
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
// control. The academy advertises exactly these six as trial entry points; a
// first-timer must not book, say, an advanced class or an unsupervised open mat,
// even with a tampered/replayed request. Everything else (adv, gi, fund, jmma,
// omat, any future code) is rejected below.
const TRIAL_TYPE_CODES = new Set(["beg", "alev", "nogi", "mma", "jun", "mini"]);

// No slot may be booked within this window of "now" (Australia/Sydney) — a class
// starting in a few minutes helps nobody and the front desk cannot prepare.
const LEAD_TIME_MS = 2 * 60 * 60 * 1000; // 2 hours

// ---- helpers ----------------------------------------------------------------

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
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
  const firstName = str(payload.first_name, 80);
  const lastName = str(payload.last_name, 80);
  const email = str(payload.email, 160).toLowerCase();
  const phone = str(payload.phone, 40);
  const howHeard = str(payload.how_heard, 200);
  const preferredDay = str(payload.preferred_day, 400);
  const kidName = str(payload.kid_name, 120);

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
    .select("id")
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

  return json({ ok: true, waiver_token: inserted.waiver_token }, 200, origin);
});
