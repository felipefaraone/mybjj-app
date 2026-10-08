// myBJJ — notify-feedback
//
// Triggered by a Database Webhook on INSERT into public.bug_reports (configured
// in the Supabase dashboard, not in this repo). Sends an email notification via
// Resend's HTTP API so feedback gets triaged in real time instead of polling the
// table.
//
// Recipients: FEEDBACK_NOTIFY_TO (comma-separated), default the developer
// address and the academy (info@mybjj.com.au) — every type. One list, one place.
// Reply-to: the submitter's account email, so a reply from info@ reaches them;
// none when the report has no user or the account has no email (as before).
// Only a report that really exists in bug_reports is sent: this function takes
// no JWT (the webhook calls it), so a forged body must not reach the inboxes.
//
// Deployed from the dashboard until v7 (not in the repo); brought into the repo
// with the recipients / reply-to change. Deploy with --no-verify-jwt (as v7).
//
// Env:
//   RESEND_API_KEY — Resend API key with sending access on mybjj-app.com
//   FEEDBACK_NOTIFY_TO — optional; default "admin.mybjj@gmail.com,info@mybjj.com.au"
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-provided
//
// Request (from Supabase Database Webhook):
//   POST {
//     type: "INSERT",
//     table: "bug_reports",
//     record: { id, user_id, role, unit_id, type, text, page_path,
//               user_agent, app_version, created_at },
//     schema: "public",
//     old_record: null
//   }
// Success:  200 { ok: true, id: "<resend message id>" }
// Failure:  4xx/5xx { error: string }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM_EMAIL = "noreply@mybjj-app.com";
const DEFAULT_NOTIFY_TO = "admin.mybjj@gmail.com,info@mybjj.com.au";
const SUPABASE_PROJECT = "dcilltzgegqsrgatskhz";

// "a@x.com, b@y.com" -> ["a@x.com", "b@y.com"] (trimmed, lowercased, deduped,
// obviously-broken entries dropped). An empty or broken env falls back to the default.
function notifyList(): string[] {
  const parse = (v: string) => [...new Set(v.split(",").map((e) => e.trim().toLowerCase())
    .filter((e) => /^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$/.test(e)))];
  const fromEnv = parse(Deno.env.get("FEEDBACK_NOTIFY_TO") ?? "");
  return fromEnv.length ? fromEnv : parse(DEFAULT_NOTIFY_TO);
}

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

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[c] || c));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!RESEND_API_KEY) {
    console.error("notify-feedback: missing RESEND_API_KEY");
    return json({ error: "Server not configured" }, 500);
  }

  let payload: {
    type?: string;
    table?: string;
    record?: Record<string, unknown>;
  };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const r = payload.record;
  if (!r || payload.table !== "bug_reports" || payload.type !== "INSERT") {
    return json({ error: "Not a bug_reports INSERT" }, 400);
  }

  const reportId = String(r.id ?? "");
  const type = String(r.type ?? "general");
  const role = String(r.role ?? "user");
  const text = String(r.text ?? "");
  const pagePath = String(r.page_path ?? "");
  const userAgent = String(r.user_agent ?? "");
  const appVersion = String(r.app_version ?? "");
  const createdAt = String(r.created_at ?? "");
  const userId = String(r.user_id ?? "");
  const unitId = String(r.unit_id ?? "");

  // Plain text header: no HTML escaping applies; line breaks are removed so a
  // client-supplied type / role can never break the header.
  const subject = `[myBJJ feedback] ${type} from ${role}`.replace(/[\r\n]+/g, " ");

  // Only a real row is sent (see header). The content below still comes from the
  // webhook body, exactly as before.
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(reportId)) {
    return json({ error: "Not a bug_reports INSERT" }, 400);
  }
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: row, error: rowErr } = await supabase.from("bug_reports").select("id").eq("id", reportId).maybeSingle();
  if (rowErr) {
    // Could not check: send anyway rather than lose a real report (the webhook
    // does not retry).
    console.error("notify-feedback: report lookup failed", rowErr.message);
  } else if (!row) {
    return json({ error: "No such report" }, 404);
  }

  // Reply-to: the submitter's account email, when there is one.
  let replyTo: string | null = null;
  if (userId) {
    try {
      const { data: u } = await supabase.auth.admin.getUserById(userId);
      const e = String(u?.user?.email ?? "").trim();
      if (e) replyTo = e;
    } catch (e) {
      console.error("notify-feedback: user lookup failed", e instanceof Error ? e.message : String(e));
    }
  }
  const dashboardUrl = `https://supabase.com/dashboard/project/${SUPABASE_PROJECT}/editor/bug_reports`;

  const html = `<!DOCTYPE html>
<html><body style="font-family:system-ui,-apple-system,sans-serif;color:#222;max-width:640px;margin:0 auto;padding:20px">
  <h2 style="margin:0 0 16px;color:#1A5DAD">New myBJJ feedback</h2>
  <table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:20px">
    <tr><td style="padding:6px 0;color:#666;width:120px">Type</td><td style="padding:6px 0"><strong>${escapeHtml(type)}</strong></td></tr>
    <tr><td style="padding:6px 0;color:#666">Role</td><td style="padding:6px 0">${escapeHtml(role)}</td></tr>
    <tr><td style="padding:6px 0;color:#666">App version</td><td style="padding:6px 0">${escapeHtml(appVersion)}</td></tr>
    <tr><td style="padding:6px 0;color:#666">Page</td><td style="padding:6px 0"><code>${escapeHtml(pagePath)}</code></td></tr>
    <tr><td style="padding:6px 0;color:#666">User agent</td><td style="padding:6px 0;font-size:12px;color:#888">${escapeHtml(userAgent)}</td></tr>
    <tr><td style="padding:6px 0;color:#666">Received</td><td style="padding:6px 0">${escapeHtml(createdAt)}</td></tr>
  </table>
  <h3 style="margin:20px 0 8px;font-size:14px;color:#666;text-transform:uppercase;letter-spacing:.05em">Message</h3>
  <pre style="background:#f5f6f8;border:1px solid #e5e7eb;border-radius:6px;padding:14px;white-space:pre-wrap;font-family:inherit;font-size:14px;line-height:1.5;margin:0 0 20px">${escapeHtml(text)}</pre>
  <p style="margin:20px 0"><a href="${dashboardUrl}" style="display:inline-block;background:#1A5DAD;color:#fff;text-decoration:none;padding:10px 18px;border-radius:6px;font-weight:600;font-size:14px">Open in Supabase</a></p>
  <hr style="border:0;border-top:1px solid #e5e7eb;margin:24px 0">
  <p style="font-size:11px;color:#888;margin:0">Report ID: <code>${escapeHtml(reportId)}</code><br>User ID: <code>${escapeHtml(userId)}</code><br>Unit ID: <code>${escapeHtml(unitId)}</code></p>
</body></html>`;

  const textBody = `New myBJJ feedback

Type: ${type}
Role: ${role}
App version: ${appVersion}
Page: ${pagePath}
User agent: ${userAgent}
Received: ${createdAt}

Message:
${text}

Open in Supabase: ${dashboardUrl}

Report ID: ${reportId}
User ID: ${userId}
Unit ID: ${unitId}`;

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${RESEND_API_KEY}`,
    },
    body: JSON.stringify({
      from: `myBJJ Feedback <${FROM_EMAIL}>`,
      to: notifyList(),
      ...(replyTo ? { reply_to: replyTo } : {}),
      subject,
      html,
      text: textBody,
    }),
  });

  if (!resendRes.ok) {
    const errBody = await resendRes.text();
    console.error("notify-feedback: Resend failed", resendRes.status, errBody);
    return json({ error: `Resend failed: ${errBody}` }, 500);
  }

  const result = await resendRes.json();
  console.log(`notify-feedback: sent for report ${reportId} (resend id ${result.id})`);
  return json({ ok: true, id: result.id });
});