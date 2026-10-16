// supabase/functions/tv-show/index.ts
//
// The gym TV board's data (migration 155). Public: the TV page (tv.html) runs on
// an AbleSign player with no session, so the screen's token in the URL is the
// only credential.
//
//   GET ?t=<token>
//   -> 200 <tv_payload json>   photo paths swapped for short-lived signed URLs
//   -> 400 {"ok": false, "error": "missing_token"}
//   -> 404 {"ok": false, "error": "unknown_screen"}   unknown, malformed or inactive
//   -> 405                                              anything but GET / OPTIONS
//   -> 503 {"ok": false, "error": "unavailable"}        database error (the TV keeps
//                                                       its last payload on screen)
//
// The token is hashed here (sha256 hex) and only the hash reaches the database
// (tv_screens.token_hash). Neither the token nor the hash is ever logged or
// returned. tv_payload is executable only by service_role.
//
// The avatars bucket is PRIVATE (migration 84): every photo_path in the payload
// (adults only; tv_payload never sends one for a kid) becomes photo_url, signed
// for an hour, in ONE storage request.
//
// Deploy with --no-verify-jwt (config.toml: verify_jwt = false).
// Auto-provided: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. No other secrets.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = ["https://mybjj-app.com"];
const SIGNED_TTL = 3600; // seconds
const TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    // Kept IDENTICAL across all Edge Functions.
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...corsHeaders(origin) },
  });
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Every object in the payload that carries a photo_path.
type WithPhoto = { photo_path?: unknown; photo_url?: string | null };
function collectPhotos(v: unknown, out: WithPhoto[]) {
  if (Array.isArray(v)) { for (const x of v) collectPhotos(x, out); return; }
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if ("photo_path" in o) out.push(o as WithPhoto);
    for (const k of Object.keys(o)) if (k !== "photo_path") collectPhotos(o[k], out);
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "GET") return json({ ok: false, error: "method_not_allowed" }, 405, origin);

  const token = new URL(req.url).searchParams.get("t");
  if (!token) return json({ ok: false, error: "missing_token" }, 400, origin);
  if (!TOKEN_RE.test(token)) return json({ ok: false, error: "unknown_screen" }, 404, origin);

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    console.error("[tv-show] missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    return json({ ok: false, error: "unavailable" }, 503, origin);
  }
  const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data, error } = await sb.rpc("tv_payload", { p_token_hash: await sha256Hex(token) });
  if (error) {
    // code only: never the token, the hash or the parameters
    console.error("[tv-show] tv_payload failed:", error.code || "unknown");
    return json({ ok: false, error: "unavailable" }, 503, origin);
  }
  if (!data) return json({ ok: false, error: "unknown_screen" }, 404, origin);

  // Sign every photo path in one request. A path that fails to sign (or a legacy
  // full URL, which the private bucket would refuse anyway) becomes null: the TV
  // falls back to initials.
  const holders: WithPhoto[] = [];
  collectPhotos(data, holders);
  const paths = [...new Set(holders.map((h) => h.photo_path)
    .filter((p): p is string => typeof p === "string" && p !== "" && !/^https?:/i.test(p)))];
  const signed = new Map<string, string>();
  if (paths.length) {
    const r = await sb.storage.from("avatars").createSignedUrls(paths, SIGNED_TTL);
    if (r.error) console.error("[tv-show] sign failed:", r.error.message);
    for (const row of r.data || []) if (row.path && row.signedUrl) signed.set(row.path, row.signedUrl);
  }
  for (const h of holders) {
    const p = typeof h.photo_path === "string" ? h.photo_path : "";
    h.photo_url = signed.get(p) || null;
    delete h.photo_path;
  }

  return json(data, 200, origin);
});
