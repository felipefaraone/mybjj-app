// myBJJ — Phase 8 — admin-change-email
//
// Admin-of-other email change. The admin_change_user_email RPC updates the
// PUBLIC tables (users / students / staff / whitelist) and enforces the
// caller's is_admin()/is_staff() + unit-scope authorization — but Postgres
// cannot reach the auth schema, so auth.users.email stays stale and the magic
// link keeps going to the OLD address. This function runs the RPC (as the
// caller, so its authorization still applies) and THEN syncs auth.users via
// auth.admin.updateUserById.
//
// Deployed without JWT verification on the Supabase side (`--no-verify-jwt`)
// because we extract the caller's JWT from the Authorization header and verify
// it ourselves so we can also check the caller's role.
//
// Flow:
//   1. Verify caller's JWT and load their public.users row.
//   2. Caller must have role owner / admin / instructor.
//   3. Validate body { target_kind, target_db_id, new_email }.
//   4. Run admin_change_user_email AS THE CALLER (anon key + Authorization
//      header) so the RPC's own authorization/unit checks apply. On RPC
//      error: return it and do NOT touch auth.
//   5. Only on RPC success: resolve the target's linked auth user_id
//      (service role). Null => nothing to sync, return authUpdated:false.
//   6. auth.admin.updateUserById(user_id, { email, email_confirm:true }).
//
// Env (auto-injected by Supabase):
//   SUPABASE_URL                — project URL
//   SUPABASE_SERVICE_ROLE_KEY   — service role JWT
//   SUPABASE_ANON_KEY           — anon key (for the caller-scoped RPC call)
//
// Request:  POST { target_kind: 'student'|'staff', target_db_id: uuid, new_email: string }
// Success:  200 { ok: true, authUpdated: boolean }
// Failure:  4xx/5xx { error: string }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

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
    console.error("admin-change-email: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY");
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
    console.warn("admin-change-email: getUser failed", userErr?.message);
    return json({ error: "Not authenticated" }, 401);
  }
  const callerId = userResp.user.id;

  const { data: profile, error: profErr } = await admin
    .from("users")
    .select("role")
    .eq("id", callerId)
    .single();
  if (profErr || !profile) {
    console.warn("admin-change-email: profile lookup failed", profErr?.message);
    return json({ error: "Profile not found" }, 403);
  }
  if (!["owner", "admin", "instructor"].includes(profile.role)) {
    return json({ error: "Not authorized" }, 403);
  }

  // 2. Parse + validate request
  let payload: { target_kind?: string; target_db_id?: string; new_email?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const targetKind = (payload.target_kind ?? "").trim();
  const targetDbId = (payload.target_db_id ?? "").trim();
  const newEmail = (payload.new_email ?? "").trim().toLowerCase();
  if (targetKind !== "student" && targetKind !== "staff") {
    return json({ error: "Invalid target_kind" }, 400);
  }
  if (!targetDbId) {
    return json({ error: "Missing target_db_id" }, 400);
  }
  if (!newEmail || !/^\S+@\S+\.\S+$/.test(newEmail)) {
    return json({ error: "Invalid email" }, 400);
  }

  // 3. Run the RPC AS THE CALLER (anon key + caller JWT) so the RPC's own
  //    is_admin()/is_staff() + unit-scope authorization applies. Using the
  //    service-role client here would bypass those checks — never do that.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: rpcErr } = await callerClient.rpc("admin_change_user_email", {
    p_target_kind: targetKind,
    p_target_db_id: targetDbId,
    p_new_email: newEmail,
  });
  if (rpcErr) {
    console.warn("admin-change-email: RPC failed", rpcErr.message);
    return json({ error: rpcErr.message || "Could not update email" }, 400);
  }

  // 4. RPC succeeded (public tables updated). Resolve the target's linked
  //    auth user id via the service-role client. No linkage yet => nothing
  //    to sync in auth (the person hasn't logged in), so return success.
  const table = targetKind === "staff" ? "staff" : "students";
  const { data: row, error: rowErr } = await admin
    .from(table)
    .select("user_id")
    .eq("id", targetDbId)
    .single();
  if (rowErr || !row) {
    console.error("admin-change-email: target lookup failed after RPC", rowErr?.message);
    return json({
      error: "Email updated in the app, but the linked account couldn't be resolved to sync sign-in. Update it in the Supabase dashboard.",
    }, 500);
  }
  if (!row.user_id) {
    console.log(`admin-change-email: ${table}/${targetDbId} -> ${newEmail} by ${callerId} (no auth user yet)`);
    return json({ ok: true, authUpdated: false });
  }

  // 5. Sync auth.users.email so the magic link goes to the new address.
  const { error: authErr } = await admin.auth.admin.updateUserById(row.user_id, {
    email: newEmail,
    email_confirm: true,
  });
  if (authErr) {
    console.error("admin-change-email: updateUserById failed", authErr.message);
    return json({
      error: "Email updated in the app, but the sign-in email did not sync. Update it in the Supabase dashboard. (" + (authErr.message || "auth error") + ")",
    }, 500);
  }

  console.log(`admin-change-email: ${table}/${targetDbId} -> ${newEmail} by ${callerId} (auth synced)`);
  return json({ ok: true, authUpdated: true });
});
