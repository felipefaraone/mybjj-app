// supabase/functions/waiver-submit/index.ts
//
// Public health-waiver endpoint. Reached from mybjj-app.com/waiver?t=<token>,
// where <token> is trial_bookings.waiver_token (a uuid mailed to the person in
// their booking confirmation). No login — they aren't a member yet.
//
// What it does:
//   1. resolves the token -> the trial booking (404 if unknown)
//   2. validates the Turnstile token server-side
//   3. validates the payload
//   4. uploads the drawn signature (PNG) to the PRIVATE `waivers` bucket
//   5. inserts the health_waivers row (typed safety flags + jsonb answers)
//   6. stamps trial_bookings.waiver_signed_at -> the WAIVER OK badge goes green
//
// Health data is sensitive information under the Privacy Act. Nothing here is
// ever read back to the public page: this endpoint only WRITES.
//
// Secrets required: TURNSTILE_SECRET
// Auto-injected:    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy waiver-submit --no-verify-jwt
//   (--no-verify-jwt is mandatory: the caller has no session.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://mybjj-app.com",
  "https://www.mybjj-app.com",
];

// Must match WAIVER_VERSION on the page. Bump BOTH when the legal text changes —
// we store what each person actually agreed to.
const CURRENT_WAIVER_VERSION = "2026-07-nsw-v1";

// Token is valid for 60 days from booking. After that they sign at reception.
const TOKEN_TTL_DAYS = 60;

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

function str(v: unknown, max = 400): string {
  return (typeof v === "string" ? v : "").trim().slice(0, max);
}
function bool(v: unknown): boolean {
  return v === true;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function verifyTurnstile(token: string, ip: string | null): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (!secret) return false;                       // fail closed
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

// data:image/png;base64,AAAA... -> Uint8Array
function decodeSignature(dataUrl: string): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl);
  if (!m) return null;
  try {
    const bin = atob(m[1]);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    // Signature PNGs are small. Anything over 1MB is not a signature.
    if (bytes.length === 0 || bytes.length > 1_048_576) return null;
    return bytes;
  } catch {
    return null;
  }
}

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

  // ---- 1. Turnstile (before we touch the DB) -------------------------------
  const cfToken = str(payload.turnstileToken, 4000);
  const ip = req.headers.get("cf-connecting-ip") || req.headers.get("x-forwarded-for");
  if (!(await verifyTurnstile(cfToken, ip))) {
    return json({ error: "turnstile_failed" }, 403, origin);
  }

  // ---- 2. Resolve the token -> trial booking -------------------------------
  const token = str(payload.token, 64);
  if (!UUID_RE.test(token)) {
    return json({ error: "bad_token" }, 400, origin);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: booking, error: bErr } = await supabase
    .from("trial_bookings")
    .select("id, unit_id, first_name, last_name, is_kid, kid_name, booked_at, waiver_signed_at")
    .eq("waiver_token", token)
    .maybeSingle();

  if (bErr || !booking) {
    return json({ error: "token_not_found" }, 404, origin);
  }

  // Expired link -> they sign at reception.
  const bookedAt = new Date(booking.booked_at as string).getTime();
  if (Date.now() - bookedAt > TOKEN_TTL_DAYS * 86400_000) {
    return json({ error: "token_expired" }, 410, origin);
  }

  // Already signed -> idempotent, don't create a second record.
  if (booking.waiver_signed_at) {
    return json({ ok: true, already: true }, 200, origin);
  }

  // ---- 3. Validate the payload --------------------------------------------
  const version = str(payload.waiver_text_version, 60);
  if (version !== CURRENT_WAIVER_VERSION) {
    return json({ error: "waiver_version" }, 422, origin);
  }
  if (!bool(payload.agreed)) {
    return json({ error: "not_agreed" }, 422, origin);
  }

  const isMinor = booking.is_kid === true;
  const participantName = isMinor
    ? str(booking.kid_name as string, 160)
    : `${booking.first_name} ${booking.last_name}`.trim();

  const signedByName = str(payload.signed_by_name, 160);
  if (!signedByName) {
    return json({ error: "validation", fields: ["signed_by_name"] }, 422, origin);
  }

  const sigBytes = decodeSignature(str(payload.signature, 2_000_000));
  if (!sigBytes) {
    return json({ error: "validation", fields: ["signature"] }, 422, origin);
  }

  const emergencyName  = str(payload.emergency_name, 160);
  const emergencyPhone = str(payload.emergency_phone, 40);
  if (!emergencyName || !emergencyPhone) {
    return json({ error: "validation", fields: ["emergency_contact"] }, 422, origin);
  }

  // ---- 4. Insert the waiver (we need the id for the signature path) ---------
  const waiverRow = {
    trial_booking_id:       booking.id,
    unit_id:                booking.unit_id,
    participant_name:       participantName,
    is_minor:               isMinor,
    signed_by_name:         signedByName,
    signed_by_relationship: isMinor ? str(payload.signed_by_relationship, 40) || "parent" : "self",
    waiver_text_version:    CURRENT_WAIVER_VERSION,

    emergency_name:         emergencyName,
    emergency_phone:        emergencyPhone,
    emergency_relationship: str(payload.emergency_relationship, 40) || null,

    has_asthma:          bool(payload.has_asthma),
    has_heart_condition: bool(payload.has_heart_condition),
    has_diabetes:        bool(payload.has_diabetes),
    has_epilepsy:        bool(payload.has_epilepsy),
    is_pregnant:         bool(payload.is_pregnant),
    takes_medication:    bool(payload.takes_medication),
    has_allergies:       bool(payload.has_allergies),
    has_recent_injury:   bool(payload.has_recent_injury),
    safety_notes:        str(payload.safety_notes, 2000) || null,

    // Everything else the form asked, verbatim. Not decision-critical, so it
    // stays flexible — the form can change without a migration.
    answers: (payload.answers && typeof payload.answers === "object") ? payload.answers : {},
  };

  const { data: waiver, error: wErr } = await supabase
    .from("health_waivers")
    .insert(waiverRow)
    .select("id")
    .single();

  if (wErr || !waiver) {
    console.error("[waiver-submit] insert:", wErr?.message);
    return json({ error: "insert_failed" }, 500, origin);
  }

  // ---- 5. Signature -> private bucket --------------------------------------
  const sigPath = `signature/${waiver.id}.png`;
  const { error: upErr } = await supabase.storage
    .from("waivers")
    .upload(sigPath, sigBytes, { contentType: "image/png", upsert: false });

  if (upErr) {
    console.error("[waiver-submit] signature upload:", upErr.message);
    // The waiver itself is recorded; the signature is the legal artefact, so a
    // failure here must not pass silently. Roll the row back.
    await supabase.from("health_waivers").delete().eq("id", waiver.id);
    return json({ error: "signature_failed" }, 500, origin);
  }

  await supabase
    .from("health_waivers")
    .update({ signature_path: sigPath })
    .eq("id", waiver.id);

  // ---- 6. Stamp the booking -> WAIVER OK goes green -------------------------
  const { error: stampErr } = await supabase
    .from("trial_bookings")
    .update({
      waiver_signed_at:      new Date().toISOString(),
      waiver_signed_by_name: signedByName,
      waiver_text_version:   CURRENT_WAIVER_VERSION,
    })
    .eq("id", booking.id);

  if (stampErr) {
    console.error("[waiver-submit] stamp booking:", stampErr.message);
    // The waiver exists; the badge just won't be green. Surface it rather than
    // pretending everything is fine.
    return json({ error: "stamp_failed" }, 500, origin);
  }

  return json({ ok: true }, 200, origin);
});
