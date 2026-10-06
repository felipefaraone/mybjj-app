// supabase/functions/_shared/resend_send.ts
//
// THE paced Resend sender for batch senders (trial-emails, engagement-emails:
// their real send loops AND their test mode). trial-booking sends at most 3
// emails per request and keeps its own direct call.
//
// Pacing: Resend accepts about 2 requests a second, so every request (retries
// included) starts at least SEND_GAP_MS after the previous one.
// 429: wait Retry-After (seconds or an HTTP date) when present, else 2 s, and
// retry the SAME email, up to RETRY_429_MAX times; then it is reported failed
// and the caller logs it exactly as before (retried on the next run).
// A Retry-After longer than MAX_RETRY_AFTER_MS (e.g. the daily quota is used up)
// is not waited out: the email is reported failed with `stop: true`, and the
// caller stops starting new sends this run (they stay due for the next run).
//
// Run length: an Edge Function must send its response within the 150 s request
// idle timeout (every plan; the wall-clock limit is 150 s Free / 400 s paid), and
// these functions answer only after the batch. So a run stops starting new sends
// after RUN_SEND_BUDGET_MS, and sends at most MAX_EMAILS_PER_RUN; whatever is
// left stays due and the next run continues. Worst case for the last email
// started: 0.6 s gap + 2 x 10 s waits + 3 requests, well inside 150 s.

export const SEND_GAP_MS = 600;
export const RETRY_429_MAX = 2;
export const DEFAULT_RETRY_MS = 2000;
export const MAX_RETRY_AFTER_MS = 10_000;
export const RUN_SEND_BUDGET_MS = 100_000;
export const MAX_EMAILS_PER_RUN = 60;

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export interface ResendPayload {
  from: string;
  to: string[];
  reply_to: string;
  subject: string;
  html: string;
  text: string;
}
export interface SendResult {
  ok: boolean;
  error?: string;
  attempts: number;   // HTTP requests made for this email
  stop?: boolean;     // rate limit that should end this run
}

// Retry-After: delta-seconds or an HTTP date. null when absent or unreadable.
export function retryAfterMs(h: string | null, nowMs = Date.now()): number | null {
  if (!h) return null;
  const v = h.trim();
  if (/^\d+(\.\d+)?$/.test(v)) return Math.round(parseFloat(v) * 1000);
  const t = Date.parse(v);
  return isNaN(t) ? null : Math.max(0, t - nowMs);
}

// One sender per function invocation: it holds the pacing clock and the run
// budget, counted from `startedAt` (pass the request's start time). Never throws.
export function createPacedSender(startedAt: number = Date.now()) {
  let lastStart = 0;
  let sentCount = 0;
  const url = Deno.env.get("RESEND_API_URL") || "https://api.resend.com/emails";   // test seam only

  async function paced(): Promise<void> {
    const wait = lastStart + SEND_GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    lastStart = Date.now();
  }

  async function send(payload: ResendPayload): Promise<SendResult> {
    sentCount++;
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return { ok: false, error: "RESEND_API_KEY not set", attempts: 0 };
    let attempts = 0;
    for (;;) {
      await paced();
      attempts++;
      let r: Response;
      try {
        r = await fetch(url, {
          method: "POST",
          headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
          body: JSON.stringify(payload),
        });
      } catch (e) {
        return { ok: false, error: e instanceof Error ? e.message : String(e), attempts };
      }
      if (r.ok) { await r.body?.cancel(); return { ok: true, attempts }; }
      const body = await r.text().catch(() => "<no body>");
      if (r.status === 429) {
        const ra = retryAfterMs(r.headers.get("retry-after"));
        if (ra != null && ra > MAX_RETRY_AFTER_MS) {
          return { ok: false, error: `HTTP 429 (retry after ${Math.round(ra / 1000)} s): ${body.slice(0, 200)}`, attempts, stop: true };
        }
        if (attempts <= RETRY_429_MAX) {
          await sleep(ra ?? DEFAULT_RETRY_MS);
          continue;
        }
      }
      return { ok: false, error: `HTTP ${r.status}: ${body.slice(0, 300)}`, attempts };
    }
  }

  return {
    send,
    // May another email be STARTED this run? (count + time budget)
    canStartAnother: () => sentCount < MAX_EMAILS_PER_RUN && Date.now() - startedAt < RUN_SEND_BUDGET_MS,
    elapsedMs: () => Date.now() - startedAt,
  };
}
