// supabase/functions/waiver-submit/index.ts
//
// Public health-waiver endpoint. Reached from mybjj-app.com/waiver?t=<token>. The
// token resolves to EITHER a lead (trial_bookings.waiver_token, mailed in the
// booking confirmation) OR an existing member (students.waiver_token, migration
// 98). No login either way — the token is the credential.
//
// What it does:
//   1. resolves the token -> a trial booking, else a student (404 if neither)
//   2. validates the Turnstile token server-side
//   3. validates the payload
//   4. uploads the drawn signature (PNG) to the PRIVATE `waivers` bucket
//   5. inserts the health_waivers row (typed safety flags + jsonb answers) with
//      trial_booking_id OR student_id set (the other NULL)
//   6. stamps waiver_signed_at; for a MEMBER, also fills the null gaps on the
//      students row (dob / gender / phone / emergency contact) — COALESCE only.
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
    // Kept IDENTICAL across all Edge Functions (no third variant). This function is
    // called from a plain page (waiver.html) that only sends content-type, so the
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

  // The same token space serves TWO kinds of person:
  //   - a LEAD   (trial_bookings.waiver_token) — 60-day TTL: a cold lead's link
  //     expires and they sign at reception; and
  //   - a MEMBER (students.waiver_token, migration 98) — NO TTL: a member is a
  //     member, their link stays valid until used.
  // Try the trial first (unchanged), then fall back to the member.
  let subject:
    | { kind: "trial"; id: string; unitId: string | null; participantName: string; isMinor: boolean }
    | { kind: "student"; id: string; unitId: string | null; participantName: string; isMinor: boolean; student: Record<string, unknown> }
    | null = null;

  const { data: booking, error: bErr } = await supabase
    .from("trial_bookings")
    .select("id, unit_id, first_name, last_name, is_kid, kid_name, booked_at, waiver_signed_at")
    .eq("waiver_token", token)
    .maybeSingle();
  if (bErr) return json({ error: "lookup_failed" }, 500, origin);

  if (booking) {
    // TRIAL path — the 60-day expiry applies here (a cold lead signs at reception).
    const bookedAt = new Date(booking.booked_at as string).getTime();
    if (Date.now() - bookedAt > TOKEN_TTL_DAYS * 86400_000) {
      return json({ error: "token_expired" }, 410, origin);
    }
    if (booking.waiver_signed_at) {
      return json({ ok: true, already: true }, 200, origin);   // idempotent
    }
    subject = {
      kind: "trial",
      id: booking.id as string,
      unitId: (booking.unit_id as string) ?? null,
      isMinor: booking.is_kid === true,
      participantName: booking.is_kid === true
        ? str(booking.kid_name as string, 160)
        : `${booking.first_name} ${booking.last_name}`.trim(),
    };
  } else {
    // MEMBER path — resolve the same token against students. NO TTL check: the
    // 60-day rule is a lead-goes-cold rule; a member's link never expires.
    const { data: student, error: sErr } = await supabase
      .from("students")
      .select("id, unit_id, full_name, prog, waiver_signed_at, date_of_birth, gender, phone, emergency_contact_name, emergency_contact_phone")
      .eq("waiver_token", token)
      .maybeSingle();
    if (sErr) return json({ error: "lookup_failed" }, 500, origin);
    if (!student) return json({ error: "token_not_found" }, 404, origin);
    if (student.waiver_signed_at) {
      return json({ ok: true, already: true }, 200, origin);   // idempotent, same as trial
    }
    subject = {
      kind: "student",
      id: student.id as string,
      unitId: (student.unit_id as string) ?? null,
      isMinor: student.prog === "kids",                        // from the row, never the client
      participantName: str(student.full_name as string, 160),
      student,
    };
  }

  // ---- 3. Validate the payload --------------------------------------------
  const version = str(payload.waiver_text_version, 60);
  if (version !== CURRENT_WAIVER_VERSION) {
    return json({ error: "waiver_version" }, 422, origin);
  }
  if (!bool(payload.agreed)) {
    return json({ error: "not_agreed" }, 422, origin);
  }

  const isMinor = subject.isMinor;
  const participantName = subject.participantName;

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
  // Participant's OWN phone (waiver.html step 1). Fills students.phone on the
  // member path; the trial path ignores it (the booking already collected one).
  const participantPhone = str(payload.participant_phone, 40);

  // ---- 4. Insert the waiver (we need the id for the signature path) ---------
  const waiverRow = {
    trial_booking_id:       subject.kind === "trial" ? subject.id : null,
    student_id:             subject.kind === "student" ? subject.id : null,
    unit_id:                subject.unitId,
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

  // ---- 6. Stamp the subject ------------------------------------------------
  const nowIso = new Date().toISOString();
  if (subject.kind === "trial") {
    // Trial: stamp the booking -> WAIVER OK goes green.
    const { error: stampErr } = await supabase
      .from("trial_bookings")
      .update({
        waiver_signed_at:      nowIso,
        waiver_signed_by_name: signedByName,
        waiver_text_version:   CURRENT_WAIVER_VERSION,
      })
      .eq("id", subject.id);
    if (stampErr) {
      console.error("[waiver-submit] stamp booking:", stampErr.message);
      // The waiver exists; the badge just won't be green. Surface it.
      return json({ error: "stamp_failed" }, 500, origin);
    }
  } else {
    // Member: FILL THE GAPS on the students row — the entire point of this door.
    // Write ONLY where the column is currently NULL (COALESCE semantics): a person
    // signing must never overwrite a correction the office already entered. The
    // current values were read at token resolution.
    const st0 = subject.student;
    const ans = (payload.answers && typeof payload.answers === "object")
      ? payload.answers as Record<string, unknown> : {};
    const ansDob = str(ans.dob, 20);
    const ansGender = str(ans.gender, 40);
    const fill: Record<string, unknown> = { waiver_signed_at: nowIso };
    if (!st0.date_of_birth && /^\d{4}-\d{2}-\d{2}$/.test(ansDob)) fill.date_of_birth = ansDob;
    if (!st0.gender && ansGender) fill.gender = ansGender;
    if (!st0.phone && participantPhone) fill.phone = participantPhone;
    if (!st0.emergency_contact_name && emergencyName) fill.emergency_contact_name = emergencyName;
    if (!st0.emergency_contact_phone && emergencyPhone) fill.emergency_contact_phone = emergencyPhone;
    const { error: fillErr } = await supabase.from("students").update(fill).eq("id", subject.id);
    if (fillErr) {
      console.error("[waiver-submit] fill student:", fillErr.message);
      return json({ error: "stamp_failed" }, 500, origin);
    }
  }

  return json({ ok: true }, 200, origin);
});
