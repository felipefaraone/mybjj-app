// myBJJ — Phase 8 — send-magic-link
//
// Dispatches a sign-in link to an email that has already been whitelisted by
// an owner / professor / coach. Deployed without JWT verification on the
// Supabase side (`--no-verify-jwt`) because we extract the caller's JWT from
// the Authorization header and verify it ourselves so we can also check the
// caller's role.
//
// Flow:
//   1. Verify caller's JWT and load their public.users row.
//   2. Caller must have role owner / admin / instructor.
//   3. Target email must exist in public.whitelist (defense against admin
//      compromise being used as a generic spam relay).
//   4. Try auth.admin.generateLink (magiclink). If the email is brand-new in
//      auth.users, generateLink errors "User not found"; fall back to
//      inviteUserByEmail which creates the auth.users row and sends the
//      invite template. Either way the user gets a clickable sign-in email
//      via the project's configured SMTP (Resend).
//
// Env (auto-injected by Supabase, no `supabase secrets set` needed):
//   SUPABASE_URL                — project URL
//   SUPABASE_SERVICE_ROLE_KEY   — service role JWT
//
// Request:  POST { email: string, redirectTo?: string }
// Success:  200 { ok: true }
// Failure:  4xx/5xx { error: string }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const DEFAULT_REDIRECT = "https://mybjj-app.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, content-type, apikey",
  "Access-Control-Max-Age": "86400",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!SUPABASE_URL || !SERVICE_ROLE || !ANON_KEY) {
    console.error("send-magic-link: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY");
    return json({ error: "Server not configured" }, 500);
  }

  // 1. Verify caller
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json({ error: "Not authenticated" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userResp, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userResp?.user) {
    console.warn("send-magic-link: getUser failed", userErr?.message);
    return json({ error: "Not authenticated" }, 401);
  }
  const callerId = userResp.user.id;

  const { data: profile, error: profErr } = await admin
    .from("users")
    .select("role")
    .eq("id", callerId)
    .single();
  if (profErr || !profile) {
    console.warn("send-magic-link: profile lookup failed", profErr?.message);
    return json({ error: "Profile not found" }, 403);
  }
  if (!["owner", "admin", "instructor"].includes(profile.role)) {
    return json({ error: "Not authorized" }, 403);
  }

  // 2. Parse request
  let payload: { email?: string; redirectTo?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const email = (payload.email ?? "").trim().toLowerCase();
  const redirectTo = (payload.redirectTo ?? DEFAULT_REDIRECT).trim() || DEFAULT_REDIRECT;
  if (!email || !/^\S+@\S+\.\S+$/.test(email)) {
    return json({ error: "Invalid email" }, 400);
  }

  // 3. Whitelist gate — caller must have already saved this email through
  //    one of the admin flows that upserts public.whitelist (Add Student,
  //    Add Staff, parent_email upsert). Stops the function from being a
  //    generic email-spam endpoint if a staff JWT is ever leaked.
  const { data: wl, error: wlErr } = await admin
    .from("whitelist")
    .select("email")
    .eq("email", email)
    .maybeSingle();
  if (wlErr) {
    console.error("send-magic-link: whitelist lookup failed", wlErr);
    return json({ error: "Lookup failed" }, 500);
  }
  if (!wl) {
    return json({ error: "Email not in whitelist" }, 400);
  }

  // 4. Dispatch via the standard signInWithOtp path. auth.admin.generateLink
  //    only returns a URL — it does NOT trigger the SMTP send pipeline, so
  //    Resend was logging nothing. signInWithOtp does go through SMTP and
  //    uses the project's Magic Link email template. shouldCreateUser:true
  //    handles both first-time and existing addresses in one call.
  //
  //    This call must use the anon-key client (not the service-role one) —
  //    GoTrue routes signInWithOtp differently for service-role callers.
  const anonClient = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: otpErr } = await anonClient.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: redirectTo, shouldCreateUser: true },
  });
  if (otpErr) {
    const msg = (otpErr.message ?? "").toLowerCase();
    if (/rate/.test(msg)) return json({ error: "Rate limit exceeded" }, 429);
    console.warn("send-magic-link: signInWithOtp failed", otpErr);
    return json({ error: otpErr.message }, 500);
  }

  console.log(`send-magic-link: sent to ${email} by ${callerId}`);
  return json({ ok: true });
});
