// supabase/functions/_shared/test_to.ts
//
// Test send mode ({"test_to": "<address>"}) for trial-emails and engagement-emails.
// Accepts exactly ONE syntactically valid address as a plain string: no lists,
// no commas or semicolons, no display names, no whitespace inside. Anything else
// is refused, so a test can never fan out to several inboxes.
export function parseTestTo(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const e = v.trim();
  if (e.length < 6 || e.length > 254) return null;
  if (!/^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/.test(e)) return null;
  const [local, domain] = e.split("@");
  if (local.length > 64 || local.startsWith(".") || local.endsWith(".") || local.includes("..")) return null;
  if (!/\.[A-Za-z]{2,}$/.test(domain)) return null;
  return e.toLowerCase();
}

export const TEST_SUBJECT_PREFIX = "[TEST] ";
// Resend allows about 2 requests a second; a test sends up to 18 in a row.
export const TEST_SEND_GAP_MS = 600;
export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
