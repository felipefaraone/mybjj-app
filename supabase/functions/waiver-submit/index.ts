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

  // ---- 2. Resolve the subject ----------------------------------------------
  // Two doors into this endpoint:
  //   • TOKENED — a link with ?t=<uuid> that resolves to a trial LEAD or a MEMBER
  //     (both unchanged below).
  //   • GENERIC — the fixed public waiver link that replaces the JotForm: NO token,
  //     an explicit `generic:true` flag. We mint a BRAND-NEW trial lead and attach
  //     the waiver to it. The explicit flag matters — a merely-missing token on a
  //     tokened link must still 400 (bad_token), never silently create a junk lead.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const token = str(payload.token, 64);
  const isGeneric = payload.generic === true && !token;

  let subject:
    | { kind: "trial"; id: string; unitId: string | null; participantName: string; isMinor: boolean }
    | { kind: "student"; id: string; unitId: string | null; participantName: string; isMinor: boolean; student: Record<string, unknown> }
    | null = null;
  // Generic path: hold the new lead's fields and create the trial_bookings row
  // JUST BEFORE the waiver insert (step 4), so a bot or an incomplete submit never
  // leaves an orphan lead (turnstile + contact + full waiver payload all validate
  // first).
  let genericLead: {
    first_name: string; last_name: string; email: string; phone: string;
    is_kid: boolean; kid_name: string | null; unit_id: string | null;
  } | null = null;

  if (isGeneric) {
    // The generic form supplies the person's OWN contact fields (there's no
    // pre-existing booking to read them from). Minimal required set: a first name +
    // a valid-shaped email. unit_id is best-effort — a real unit uuid is kept, else
    // null (Patricia assigns the location later); we never reject on unit alone.
    const gFirst = str(payload.first_name, 120);
    const gLast  = str(payload.last_name, 120);
    const gEmail = str(payload.email, 200).toLowerCase();
    const gPhone = str(payload.phone, 40);
    const gIsKid = payload.is_kid === true;
    const gKid   = gIsKid ? str(payload.kid_name, 160) : "";
    if (!gFirst) return json({ error: "bad_request", fields: ["first_name"] }, 400, origin);
    if (!gEmail || !/^\S+@\S+\.\S+$/.test(gEmail)) return json({ error: "bad_request", fields: ["email"] }, 400, origin);
    const gUnit = str(payload.unit_id, 64);
    const unitId = UUID_RE.test(gUnit) ? gUnit : null;
    genericLead = { first_name: gFirst, last_name: gLast, email: gEmail, phone: gPhone, is_kid: gIsKid, kid_name: gIsKid ? (gKid || null) : null, unit_id: unitId };
    subject = {
      kind: "trial",
      id: "",                                            // filled when the lead is created in step 4
      unitId,
      isMinor: gIsKid,
      participantName: gIsKid ? gKid : `${gFirst} ${gLast}`.trim(),
    };
  } else {
    // ---- TOKENED path (unchanged) -------------------------------------------
    if (!UUID_RE.test(token)) {
      return json({ error: "bad_token" }, 400, origin);
    }
    // The same token space serves TWO kinds of person:
    //   - a LEAD   (trial_bookings.waiver_token) — 60-day TTL: a cold lead's link
    //     expires and they sign at reception; and
    //   - a MEMBER (students.waiver_token, migration 98) — NO TTL: a member is a
    //     member, their link stays valid until used.
    // Try the trial first (unchanged), then fall back to the member.
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

  // ---- 4. Resolve the trial lead (we need the id for the signature path) ----
  // Generic path: FIND-OR-CREATE the trial lead NOW (just-in-time). Everything that
  // could reject a bad/incomplete submit — turnstile, contact fields, and the full
  // waiver payload above — has already passed, so this is the last gate before
  // there's a real subject to attach the waiver to.
  if (isGeneric && genericLead && subject) {
    // ---- SHORT-WINDOW IDEMPOTENCY (a repeat of the SAME submit) --------------
    // Separate from, and prior to, the 60-day de-dupe below. That one answers a
    // different question — "did this person already book a trial they have not
    // signed for?" — and filters on `waiver_signed_at IS NULL`, so by design it
    // cannot see a lead that was signed seconds ago.
    //
    // KEYED ON THE PARTICIPANT, NOT THE EMAIL. For an adult the participant IS
    // the signer, so the email identifies them. For a child it does NOT: on the
    // public form a parent signs SEPARATELY for each of their children from the
    // same address, so the key must include the child. Production has exactly
    // that — one parent, one email, two submits 87 seconds apart for "Ari
    // Deutsch" and "Asha Deutsch". Two different children, two legitimate
    // waivers. An email-only rule silently discards the second child while
    // returning success to the parent, which is why the earlier attempt at this
    // fix was reverted. A parent signing for a second child MUST get a second
    // lead.
    //
    // kid_name is compared case-insensitively: the form only trims (val() in
    // waiver.html) and never normalises case, unlike email which is lowercased
    // on the way in at line 165.
    //
    // The window is deliberately SHORT. It absorbs a double-click, a network
    // retry, and an unsure user pressing submit again. It is NOT a business rule
    // about when renewed interest counts as a new prospect — that judgement
    // belongs to the staff working the prospect list. Do not widen it into one.
    //
    // Runs before any write: nothing has been inserted, uploaded or stamped at
    // this point in the handler.
    const idemKidName = genericLead.is_kid ? (genericLead.kid_name || "") : "";
    // A kid submit with no name gives us nothing to identify the participant by,
    // so skip rather than risk discarding a second child — the exact mistake the
    // revert was about.
    if (!genericLead.is_kid || idemKidName) {
      const tenMinutesAgo = new Date(Date.now() - 10 * 60_000).toISOString();
      // Same escaping as the de-dupe below: ILIKE with SQL-LIKE metachars escaped
      // so a literal "_"/"%" matches literally rather than as a wildcard.
      const emailPatRecent = genericLead.email.replace(/[\\%_*]/g, "\\$&");
      let idemQ = supabase
        .from("trial_bookings")
        .select("id")
        .ilike("email", emailPatRecent)
        .eq("is_kid", genericLead.is_kid)
        // A NULL waiver_signed_at fails `gte`, so unsigned leads are excluded here
        // and stay the business of the 60-day de-dupe below.
        .gte("waiver_signed_at", tenMinutesAgo);
      if (genericLead.is_kid) {
        idemQ = idemQ.ilike("kid_name", idemKidName.replace(/[\\%_*]/g, "\\$&"));
      }
      const { data: recentSigned, error: recentErr } = await idemQ
        .order("waiver_signed_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (recentErr) {
        // Same posture as the de-dupe below — a lookup hiccup must never block a
        // genuine signup. Fall through to the existing behaviour.
        console.error("[waiver-submit] generic idempotency lookup:", recentErr.message);
      } else if (recentSigned) {
        // Repeat submit for the SAME participant: no lead, no health_waivers row,
        // no signature upload, no stamp. Return the SAME body a completed submit
        // returns, so the caller cannot tell a repeat from the original.
        console.log("[waiver-submit] generic repeat submit within 10m, ignored (lead", recentSigned.id, ")");
        return json({ ok: true }, 200, origin);
      }
    }

    // De-dupe: a person who already booked (has a trial_bookings row) but fills the
    // GENERIC waiver instead of their personal link must NOT get a second trial.
    // Look for a reuse candidate FIRST — same email, waiver NOT yet signed, booked
    // within the last 60 days (the same TTL as token expiry, so a stale old lead
    // never silently absorbs a fresh signup), most recent first.
    //
    // Case-insensitive match via ILIKE with SQL-LIKE metachars escaped, so a literal
    // "_"/"%" in an email is matched literally, not as a wildcard. (Both current
    // insert paths — trial-booking and this generic path — already lowercase email;
    // ILIKE additionally guards any legacy mixed-case rows.)
    const sixtyDaysAgo = new Date(Date.now() - 60 * 86400_000).toISOString();
    const emailPat = genericLead.email.replace(/[\\%_*]/g, "\\$&");
    const { data: existing, error: findErr } = await supabase
      .from("trial_bookings")
      .select("id, unit_id")
      .ilike("email", emailPat)
      .is("waiver_signed_at", null)
      .gte("booked_at", sixtyDaysAgo)
      .order("booked_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (findErr) {
      // A lookup hiccup must not block the signup — fall through to create a fresh
      // lead (worst case a duplicate, i.e. the pre-dedupe behaviour).
      console.error("[waiver-submit] generic dedupe lookup:", findErr.message);
    }

    if (existing) {
      // REUSE — attach the waiver to the existing trial and stamp ITS
      // waiver_signed_at (below). Do NOT overwrite the original booking's
      // name/phone/etc (that data is authoritative — this is the same person
      // re-entering). Only FILL a NULL unit_id from the form, never overwrite one.
      subject.id = existing.id as string;
      if (!existing.unit_id && genericLead.unit_id) {
        const { error: uErr } = await supabase
          .from("trial_bookings")
          .update({ unit_id: genericLead.unit_id })
          .eq("id", existing.id);
        if (uErr) console.error("[waiver-submit] generic dedupe unit fill:", uErr.message);
      }
    } else {
      // No candidate → CREATE a new lead (unchanged behaviour). how_heard marks the
      // generic-form origin; a fresh waiver_token is set explicitly (the tokened
      // flow relies on it, and the column also DB-defaults one).
      const { data: lead, error: leadErr } = await supabase
        .from("trial_bookings")
        .insert({
          first_name:   genericLead.first_name,
          last_name:    genericLead.last_name,
          email:        genericLead.email,
          phone:        genericLead.phone,
          is_kid:       genericLead.is_kid,
          kid_name:     genericLead.kid_name,
          unit_id:      genericLead.unit_id,
          how_heard:    "Website waiver",
          waiver_token: crypto.randomUUID(),
          trial_status: "booked",
          booked_at:    new Date().toISOString(),
        })
        .select("id")
        .single();
      if (leadErr || !lead) {
        console.error("[waiver-submit] generic lead insert:", leadErr?.message);
        return json({ error: "lead_create_failed" }, 500, origin);
      }
      subject.id = lead.id as string;   // the placeholder id set in step 2 is now real
    }
  }

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
