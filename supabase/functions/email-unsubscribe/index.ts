// supabase/functions/email-unsubscribe/index.ts
//
// Records an opt-out from the engagement emails (migration 137). JSON only: the
// page people see is the static https://mybjj-app.com/unsubscribe.html, which
// changes nothing on load and POSTs here only when a button is pressed (email
// security scanners open links in emails by themselves; a GET here records
// nothing — it is refused with 405).
//
//   POST {"email": "...", "kind": "monthly_recap|mia|all", "sig": "<hex>"}
//   -> 200 {"ok": true}            opt-out stored (idempotent)
//   -> 400 {"ok": false, "error"}  bad body or signature
//   -> 403                         a browser call from any origin but the site
//   -> 405                         anything but POST / OPTIONS
//
// sig = HMAC-SHA256(EMAIL_UNSUB_SECRET, lowercased-trimmed-email + "|" + kind),
// the SAME rule engagement-emails signs its links with. A tampered email or kind
// fails it.
//
// Deploy with --no-verify-jwt (no session on the page).
// Secrets: EMAIL_UNSUB_SECRET. Auto-provided: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Only the public site may call this from a browser.
const ALLOWED_ORIGINS = ["https://mybjj-app.com"];
const KINDS = new Set(["monthly_recap", "mia", "all"]);

// Same shape as trial-booking: echo an allowed origin, else the first allowed one
// (which the browser then refuses for any other origin).
function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
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

function safeEqual(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const BAD = "This unsubscribe link isn't valid. Reply to any of our emails and we'll take you off the list.";

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  // A browser on any other site: refuse before doing anything. (Server-to-server
  // calls send no Origin and still need a valid signature.)
  if (origin && !ALLOWED_ORIGINS.includes(origin)) {
    return json({ ok: false, error: "origin not allowed" }, 403, origin);
  }
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405, origin);

  const secret = Deno.env.get("EMAIL_UNSUB_SECRET");
  if (!secret) return json({ ok: false, error: BAD }, 400, origin); // fail closed

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: BAD }, 400, origin); }
  const email = String(body.email ?? "").trim().toLowerCase();
  const kind = String(body.kind ?? "");
  const sig = String(body.sig ?? "").toLowerCase();
  if (!email || email.length > 320 || !KINDS.has(kind) || !/^[0-9a-f]{64}$/.test(sig)) {
    return json({ ok: false, error: BAD }, 400, origin);
  }
  if (!safeEqual(sig, await hmacHex(secret, email + "|" + kind))) {
    return json({ ok: false, error: BAD }, 400, origin);
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await supabase.from("email_optouts")
    .upsert({ email, kind }, { onConflict: "email,kind", ignoreDuplicates: true });
  if (error) {
    console.error("[email-unsubscribe] insert failed:", error.message);
    return json({ ok: false, error: "Something went wrong. Please try again in a moment." }, 500, origin);
  }
  return json({ ok: true, kind }, 200, origin);
});
