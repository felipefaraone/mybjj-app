// supabase/functions/trial-booking/index.ts
//
// Public trial-booking endpoint. This is the ONLY write path for the public
// booking form (mybjj-app.com/trial.html). It:
//   1. validates the Cloudflare Turnstile token server-side (the real spam gate),
//   2. validates the payload,
//   3. inserts into public.trial_bookings with the service role,
//      forcing trial_status='booked' and stamping the waiver.
//
// Because the insert happens here (service role), the public page carries NO
// Supabase credentials, and the anon INSERT policy on trial_bookings can be
// removed once this is live (see deploy notes).
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

// Map the two live units' legacy ids to accept a friendly ?unit=nb|cd.
// The function resolves legacy -> uuid from the units table, so no uuid is
// hard-coded here; this set just whitelists which legacy ids the form may send.
const ALLOWED_UNIT_LEGACY = new Set(["nb", "cd"]);

// The waiver version the CURRENT page text corresponds to. The page sends its
// own version too; we trust the server value as the source of truth for what
// was actually accepted, and reject a mismatch so an old cached page can't
// record acceptance of text we no longer show.
const CURRENT_WAIVER_VERSION = "2026-07-nsw-v1-PLACEHOLDER";

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

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function str(v: unknown, max = 200): string {
  return (typeof v === "string" ? v : "").trim().slice(0, max);
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

  // 2. Validate payload.
  const unitLegacy = str(payload.unit_legacy_id, 16).toLowerCase();
  const firstName = str(payload.first_name, 80);
  const lastName = str(payload.last_name, 80);
  const email = str(payload.email, 160).toLowerCase();
  const phone = str(payload.phone, 40);
  const howHeard = str(payload.how_heard, 200);
  const preferredDay = str(payload.preferred_day, 200);
  const isKid = payload.is_kid === true;
  const kidName = str(payload.kid_name, 120);
  const waiverName = str(payload.waiver_signed_by_name, 160);
  const waiverAgreed = payload.waiver_agreed === true;
  const waiverVersion = str(payload.waiver_text_version, 60);

  const errors: string[] = [];
  if (!ALLOWED_UNIT_LEGACY.has(unitLegacy)) errors.push("unit");
  if (!firstName) errors.push("first_name");
  if (!lastName) errors.push("last_name");
  if (!EMAIL_RE.test(email)) errors.push("email");
  if (!phone) errors.push("phone");
  if (!waiverAgreed) errors.push("waiver_agreed");
  if (!waiverName) errors.push("waiver_signed_by_name");
  // The accepted text must match the version this function currently serves.
  if (waiverVersion !== CURRENT_WAIVER_VERSION) errors.push("waiver_version");
  // For a kid trial the child's name is required (the parent's name goes in
  // first/last + waiver_signed_by_name — the guardian who accepts).
  if (isKid && !kidName) errors.push("kid_name");

  if (errors.length) {
    return json({ error: "validation", fields: errors }, 422, origin);
  }

  // 3. Resolve unit uuid and insert with the service role.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: unitRow, error: unitErr } = await supabase
    .from("units")
    .select("id")
    .eq("legacy_id", unitLegacy)
    .eq("active", true)
    .maybeSingle();

  if (unitErr || !unitRow) {
    return json({ error: "unit_not_found" }, 422, origin);
  }

  const nowISO = new Date().toISOString();
  const { error: insErr } = await supabase.from("trial_bookings").insert({
    unit_id: unitRow.id,
    first_name: firstName,
    last_name: lastName,
    email,
    phone,
    how_heard: howHeard || null,
    preferred_day: preferredDay || null,
    is_kid: isKid,
    kid_name: isKid ? kidName : null,
    trial_status: "booked",
    booked_at: nowISO,
    waiver_signed_at: nowISO,
    waiver_signed_by_name: waiverName,
    // Trust the SERVER version, not whatever the client claimed.
    waiver_text_version: CURRENT_WAIVER_VERSION,
  });

  if (insErr) {
    console.error("[trial-booking] insert error:", insErr.message);
    return json({ error: "insert_failed" }, 500, origin);
  }

  return json({ ok: true }, 200, origin);
});
