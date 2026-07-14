// supabase/functions/send-waiver-link/index.ts
//
// Emails an EXISTING member the link to their health waiver
// (mybjj-app.com/waiver.html?t=<students.waiver_token>). Called from INSIDE the
// app by a signed-in staff member — so, unlike the public waiver-submit /
// trial-booking functions, this is deployed WITH jwt verification:
//
//   supabase functions deploy send-waiver-link         (verify_jwt = ON)
//
// The caller's session proves who they are; we still re-check they're staff
// (is_staff() OR is_admin()) server-side — never trust the client — and only then
// send. The email must NEVER break anything: a dead Resend is logged (status +
// body) and swallowed, and we report sent:false rather than 500.
//
// Secrets required:  RESEND_API_KEY
// Auto-injected:     SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://mybjj-app.com",
  "https://www.mybjj-app.com",
];

// Same sender identity as trial-booking (verified Resend domain; replies land in
// the academy inbox, not a black hole).
const FROM = "myBJJ <noreply@mybjj-app.com>";
const REPLY_TO = "info@mybjj.com.au";
const WAIVER_ORIGIN = "https://mybjj-app.com";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    // Every header the client actually sends. Called through a raw fetch from the
    // app WITH the supabase apikey + Authorization, so the preflight must allow
    // them all — omitting `apikey` is exactly what blocked this function at CORS.
    // Kept IDENTICAL to trial-booking / waiver-submit so there is no third variant.
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
function str(v: unknown, max = 200): string {
  return (typeof v === "string" ? v : "").trim().slice(0, max);
}
function escHtml(s: string): string {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// Plain, short. Adult → addressed to the member; kid → addressed to the parent,
// said plainly to be for their child and that a guardian must sign.
function buildEmail(name: string, waiverLink: string, isKid: boolean): { subject: string; html: string; text: string } {
  const subject = "myBJJ — your health check";
  const who = name || "there";
  const lead = isKid
    ? `We're bringing every member's health details into the app. Please take three minutes to complete the health check for your child, ${who} — it's the medical info the coaches need if something happens to them on the mat. A parent or guardian needs to sign it.`
    : `We're bringing everyone's health details into the app. Please take three minutes to complete your health check — it's the medical info the coaches need if something happens to you on the mat.`;
  const greeting = isKid ? "Hi," : `Hi ${who},`;

  const text = [
    greeting,
    ``,
    lead,
    ``,
    `Complete it here:`,
    waiverLink,
    ``,
    `If anything looks wrong, just reply to this email.`,
    ``,
    `myBJJ`,
  ].join("\n");

  const html = `<div style="margin:0;padding:0;background:#f5f7fa">
  <div style="max-width:560px;margin:0 auto;padding:24px 20px;font-family:Arial,Helvetica,sans-serif;color:#16202b">
    <p style="font-size:16px;margin:0 0 14px">${escHtml(greeting)}</p>
    <p style="font-size:14.5px;color:#5a6a78;line-height:1.6;margin:0 0 22px">${escHtml(lead)}</p>
    <a href="${escHtml(waiverLink)}" style="display:block;background:#1A5DAD;color:#ffffff;text-decoration:none;text-align:center;font-size:17px;font-weight:700;padding:15px 20px;border-radius:10px">Complete your health check</a>
    <p style="font-size:13.5px;color:#5a6a78;margin:12px 0 24px;text-align:center">About three minutes.</p>
    <p style="font-size:14px;color:#5a6a78;line-height:1.6;margin:0;border-top:1px solid #e1e7ee;padding-top:16px">
      If anything looks wrong, just reply to this email.<br>
      <strong style="color:#16202b">myBJJ</strong>
    </p>
  </div>
</div>`;

  return { subject, html, text };
}

// Send via Resend. NEVER throws — logs status+body, and returns WHY it did or
// didn't land so the client can name the cause instead of "could not send".
async function sendViaResend(to: string, msg: { subject: string; html: string; text: string }): Promise<{ sent: boolean; reason: string }> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) { console.error("[send-waiver-link] RESEND_API_KEY not set — email skipped"); return { sent: false, reason: "not_configured" }; }
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [to], reply_to: REPLY_TO, subject: msg.subject, html: msg.html, text: msg.text }),
    });
    if (!r.ok) {
      const body = await r.text().catch(() => "<no body>");
      console.error(`[send-waiver-link] Resend rejected: HTTP ${r.status} — ${body}`);
      return { sent: false, reason: "resend_rejected" };
    }
    return { sent: true, reason: "ok" };
  } catch (e) {
    console.error("[send-waiver-link] Resend threw:", e instanceof Error ? e.message : String(e));
    return { sent: false, reason: "network" };
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, origin);

  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json({ error: "bad_json" }, 400, origin); }

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // ---- Auth: the caller must be signed in AND staff. -----------------------
  const authHeader = req.headers.get("Authorization") || "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401, origin);

  const svc = createClient(url, serviceKey);
  // is_staff() = users.role in (admin,owner,instructor); is_admin() = owns a unit
  // (migration 90). Re-derived here from the data, so it can't depend on the RPCs
  // being callable — and can't be spoofed by the client.
  const { data: urow } = await svc.from("users").select("role").eq("id", user.id).maybeSingle();
  let ok = !!(urow && ["admin", "owner", "instructor"].includes(urow.role as string));
  if (!ok) {
    const { data: uo } = await svc.from("unit_owners").select("unit_id").eq("user_id", user.id).limit(1);
    if (uo && uo.length) ok = true;
    else {
      const { data: lo } = await svc.from("units").select("id").eq("owner_user_id", user.id).limit(1);
      if (lo && lo.length) ok = true;
    }
  }
  if (!ok) return json({ error: "forbidden" }, 403, origin);

  // ---- Load the student. ---------------------------------------------------
  const studentId = str(payload.student_id, 64);
  if (!UUID_RE.test(studentId)) return json({ error: "bad_student_id" }, 400, origin);

  const { data: st, error: sErr } = await svc
    .from("students")
    .select("id, full_name, prog, email, parent_email, waiver_token")
    .eq("id", studentId)
    .maybeSingle();
  if (sErr || !st) return json({ error: "student_not_found" }, 404, origin);

  const isKid = st.prog === "kids";
  // Kid → the parent gets it (parent_email, else the row's email). Adult → the
  // member's email. 215 members have no email — a clear error lets the UI fall
  // back to "copy the link and send it another way".
  const to = isKid ? (str(st.parent_email) || str(st.email)) : str(st.email);
  if (!to) return json({ error: "no_email" }, 422, origin);

  const name = str(st.full_name as string, 160);
  let link = `${WAIVER_ORIGIN}/waiver.html?t=${encodeURIComponent(String(st.waiver_token))}`;
  if (isKid) link += "&k=1";
  if (name) link += `&n=${encodeURIComponent(name)}`;

  const { sent, reason } = await sendViaResend(to, buildEmail(name, link, isKid));
  if (sent) {
    // Stamp ONLY on a real send — waiver_sent_at must never claim an email that
    // failed. On failure we do not touch the row.
    const { error: stampErr } = await svc
      .from("students")
      .update({ waiver_sent_at: new Date().toISOString() })
      .eq("id", studentId);
    if (stampErr) console.error("[send-waiver-link] stamp sent_at:", stampErr.message);
  }
  // Never 500 on a mail failure — report sent + reason so the UI can name the cause
  // and nudge to copy instead.
  return json({ ok: true, sent, reason }, 200, origin);
});
