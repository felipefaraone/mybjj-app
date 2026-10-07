// supabase/functions/_shared/unsub_link.ts
//
// The signed unsubscribe link, for any email kind. Same signing rule as
// engagement-emails and email-unsubscribe: HMAC-SHA256(EMAIL_UNSUB_SECRET,
// "<lowercased email>|<kind>"); sig signs this email's kind, sig_all signs 'all'
// so the page can also offer "Stop all emails from MyBJJ". The link goes to the
// STATIC page, which changes nothing on load.
export const UNSUB_PAGE = "https://mybjj-app.com/unsubscribe.html";

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function unsubLink(secret: string | undefined | null, email: string, kind: string): Promise<string | null> {
  if (!secret || !email) return null;
  const e = String(email).trim().toLowerCase();
  const q = new URLSearchParams({
    email: e, kind,
    sig: await hmacHex(secret, e + "|" + kind),
    sig_all: await hmacHex(secret, e + "|all"),
  });
  return `${UNSUB_PAGE}?${q.toString()}`;
}
