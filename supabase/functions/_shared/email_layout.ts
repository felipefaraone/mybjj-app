// supabase/functions/_shared/email_layout.ts
//
// THE email layout. Every email the Edge Functions send is rendered here from
// content blocks: the trial sequence (_shared/trial_emails.ts, used by
// trial-booking and trial-emails) and the monthly update (engagement-emails).
// The modules own the words; this file owns how they look.
//
// Email-client rules followed:
//   - table layout, every style inline. The one <style> block holds only the
//     small-screen media query; clients that drop it still get the desktop layout.
//   - 600px max, centred on light grey; white card, 12px radius
//   - system font stack only, no web fonts, no external CSS
//   - light colour scheme declared, so dark-mode clients don't invert it
//   - bulletproof buttons (table cell carries the colour, so the button shows
//     even with images blocked); ONE primary per email, the rest secondary
//   - hidden preheader: the first sentence of the body unless overridden
//   - header: logo + "myBJJ" wordmark on brand blue. With images blocked the bar,
//     the wordmark and the buttons all still render; the logo's alt text is set
//     in the bar's own blue, so it never shows as a second "myBJJ".
// Every value is escaped here; callers pass plain text.

export const BRAND = "#1A5DAD";
export const LOGO_URL = "https://mybjj-app.com/logo.png";   // 384x384 PNG, served publicly
const TEXT = "#16202b";
const MUTED = "#5a6a78";
const PAGE_BG = "#f3f5f8";
const PANEL_BG = "#eef4fb";
const FONT = "-apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";

export function escHtml(s: unknown): string {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// ---- blocks ----------------------------------------------------------------------
// Inline pieces: plain text, or a link.
export type Inline = string | { text: string; href: string };
export type LayoutBlock =
  | { t: "p"; parts: Inline[]; lines?: Inline[][] }   // paragraph; `lines` = one paragraph with line breaks
  | { t: "h"; text: string }                             // 20px heading
  | { t: "stat"; text: string }                          // large bold line (the monthly numbers)
  | { t: "details"; rows: { label?: string; value: Inline; strong?: boolean }[]; note?: string }
  | { t: "button"; label: string; href: string; primary: boolean; note?: string }
  | { t: "sign"; lines: string[] };

export interface LayoutFooter {
  academy?: string | null;      // "Neutral Bay" -> shown as "myBJJ Neutral Bay"
  address?: string | null;      // shown as a Maps link
  mapsUrl?: string | null;
  phone?: string | null;
  why: string;                  // "You're getting this because …"
  unsubscribeUrl?: string | null;
}

export interface LayoutEmail {
  subject: string;
  preheader?: string;           // override; default = first sentence of the body
  blocks: LayoutBlock[];
  footer: LayoutFooter;
}

// The footer's "reply" line, in the words the old trial confirmation used.
export const REPLY_LINE = "You can just reply to this email if you need anything.";

const inlineHtml = (x: Inline) =>
  typeof x === "string"
    ? escHtml(x)
    : `<a href="${escHtml(x.href)}" style="color:${BRAND};text-decoration:underline">${escHtml(x.text)}</a>`;
const inlineText = (x: Inline) => (typeof x === "string" ? x : x.text);

// First meaningful sentence: skip the greeting ("Hi Sam,").
export function defaultPreheader(blocks: LayoutBlock[]): string {
  for (const b of blocks) {
    if (b.t !== "p" && b.t !== "stat") continue;
    const s = b.t === "stat" ? b.text : b.parts.map(inlineText).join("");
    if (!s.trim() || /^(Hi|Hello)\b[^.!?]*,$/.test(s.trim())) continue;
    const m = /^.*?[.!?](?=\s|$)/.exec(s.trim());
    return (m ? m[0] : s).trim();
  }
  return "";
}

function buttonHtml(b: { label: string; href: string; primary: boolean; note?: string }): string {
  const bg = b.primary ? BRAND : "#ffffff";
  const fg = b.primary ? "#ffffff" : BRAND;
  return `<table role="presentation" border="0" cellpadding="0" cellspacing="0" align="center" class="btn" data-btn="${b.primary ? "primary" : "secondary"}" style="margin:8px auto ${b.note ? "8px" : "24px"};border-collapse:separate">
<tr><td align="center" bgcolor="${bg}" style="border-radius:10px;background-color:${bg};border:2px solid ${BRAND}">
<a href="${escHtml(b.href)}" target="_blank" class="btn-a" style="display:inline-block;min-width:220px;box-sizing:border-box;padding:14px 28px;font-family:${FONT};font-size:16px;line-height:1.2;font-weight:700;color:${fg};text-decoration:none;text-align:center;border-radius:8px">${escHtml(b.label)}</a>
</td></tr></table>${b.note ? `
<p style="margin:0 0 24px;font-family:${FONT};font-size:14px;line-height:1.5;color:${MUTED};text-align:center">${escHtml(b.note)}</p>` : ""}`;
}

function blockHtml(b: LayoutBlock): string {
  const p = (inner: string, extra = "") =>
    `<p style="margin:0 0 16px;font-family:${FONT};font-size:16px;line-height:1.6;color:${TEXT}${extra}">${inner}</p>`;
  switch (b.t) {
    case "p":
      return p(b.lines ? b.lines.map((l) => l.map(inlineHtml).join("")).join("<br>") : b.parts.map(inlineHtml).join(""));
    case "h":
      return `<h2 style="margin:24px 0 12px;font-family:${FONT};font-size:20px;line-height:1.3;font-weight:700;color:${TEXT}">${escHtml(b.text)}</h2>`;
    case "stat":
      return p(escHtml(b.text), ";font-size:20px;font-weight:700;line-height:1.4;margin:0 0 8px");
    case "sign":
      return p(b.lines.map(escHtml).join("<br>"), ";margin:24px 0 16px");
    case "button":
      return buttonHtml(b);
    case "details": {
      const rows = b.rows.map((r) => `<tr>${r.label != null
        ? `<td valign="top" style="padding:3px 16px 3px 0;font-family:${FONT};font-size:14px;line-height:1.6;color:${MUTED};white-space:nowrap">${escHtml(r.label)}</td>
<td valign="top" style="padding:3px 0;font-family:${FONT};font-size:16px;line-height:1.6;color:${TEXT}${r.strong ? ";font-weight:700" : ""}">${inlineHtml(r.value)}</td>`
        : `<td colspan="2" style="padding:2px 0;font-family:${FONT};font-size:16px;line-height:1.6;color:${TEXT}${r.strong ? ";font-weight:700;font-size:18px" : ""}">${inlineHtml(r.value)}</td>`}</tr>`).join("\n");
      const note = b.note
        ? `<tr><td colspan="2" style="padding:8px 0 0;font-family:${FONT};font-size:15px;line-height:1.6;color:${TEXT}">${escHtml(b.note)}</td></tr>` : "";
      return `<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" class="details" style="margin:4px 0 24px;border-collapse:separate">
<tr><td bgcolor="${PANEL_BG}" style="background-color:${PANEL_BG};border-left:4px solid ${BRAND};border-radius:8px;padding:16px 20px">
<table role="presentation" border="0" cellpadding="0" cellspacing="0">
${rows}${note}
</table></td></tr></table>`;
    }
  }
}

export function renderLayout(e: LayoutEmail): string {
  const pre = (e.preheader ?? defaultPreheader(e.blocks)).trim();
  const primaries = e.blocks.filter((b) => b.t === "button" && b.primary).length;
  if (primaries > 1) throw new Error("email layout: more than one primary button");
  const f = e.footer;
  const footerLines: string[] = [];
  if (f.academy) footerLines.push(`<strong style="color:${TEXT}">${escHtml("myBJJ " + f.academy)}</strong>`);
  if (f.address) {
    footerLines.push(f.mapsUrl
      ? `<a href="${escHtml(f.mapsUrl)}" style="color:${MUTED};text-decoration:underline">${escHtml(f.address)}</a>`
      : escHtml(f.address));
  }
  if (f.phone) footerLines.push(`<a href="tel:${escHtml(f.phone.replace(/[^\d+]/g, ""))}" style="color:${MUTED};text-decoration:none">${escHtml(f.phone)}</a>`);
  const fp = (inner: string, extra = "") =>
    `<p style="margin:0 0 10px;font-family:${FONT};font-size:13px;line-height:1.6;color:${MUTED}${extra}">${inner}</p>`;
  const footer = [
    footerLines.length ? fp(footerLines.join("<br>")) : "",
    fp(escHtml(REPLY_LINE)),
    fp(escHtml(f.why) + (f.unsubscribeUrl
      ? `<br><a href="${escHtml(f.unsubscribeUrl)}" style="color:${MUTED};text-decoration:underline">Unsubscribe from these emails</a>` : ""), ";margin:0"),
  ].filter(Boolean).join("\n");

  return `<!DOCTYPE html>
<html lang="en" data-layout="mybjj-email-v1">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${escHtml(e.subject)}</title>
<style>
:root { color-scheme: light; supported-color-schemes: light; }
@media only screen and (max-width: 620px) {
  .pad { padding-left: 20px !important; padding-right: 20px !important; }
  .pad-body { padding-top: 20px !important; padding-bottom: 20px !important; }
  .btn { width: 100% !important; }
  .btn-a { display: block !important; min-width: 0 !important; }
}
</style>
</head>
<body style="margin:0;padding:0;background-color:${PAGE_BG};-webkit-text-size-adjust:100%">
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;color:${PAGE_BG}">${escHtml(pre)}${"&#8203;&nbsp;".repeat(60)}</div>
<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="${PAGE_BG}" style="background-color:${PAGE_BG}">
<tr><td align="center" style="padding:24px 12px">
<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="600" style="width:100%;max-width:600px">
<tr><td>
<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="#ffffff" style="background-color:#ffffff;border-radius:12px;border-collapse:separate;overflow:hidden">
<tr><td bgcolor="${BRAND}" class="pad" style="background-color:${BRAND};border-radius:12px 12px 0 0;padding:16px 32px">
<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>
<td valign="middle" width="40" style="width:40px;padding:0 12px 0 0"><img src="${LOGO_URL}" width="40" height="40" alt="myBJJ" style="display:block;width:40px;height:40px;border:0;outline:none;text-decoration:none;font-family:${FONT};font-size:10px;color:${BRAND};background-color:${BRAND}"></td>
<td valign="middle" style="font-family:${FONT};font-size:22px;line-height:1;font-weight:700;color:#ffffff;letter-spacing:.3px">myBJJ</td>
</tr></table>
</td></tr>
<tr><td class="pad pad-body" style="padding:32px;font-family:${FONT};font-size:16px;line-height:1.6;color:${TEXT}">
${e.blocks.map(blockHtml).join("\n")}
</td></tr>
</table>
</td></tr>
<tr><td class="pad" style="padding:24px 32px 8px">
${footer}
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}
