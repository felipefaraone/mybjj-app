# myBJJ — Supabase Edge Functions

## send-magic-link

Dispatches a sign-in link to an email that has already been whitelisted by an
admin flow (Add Student, Add Staff, or parent-email upsert).

### What it does

1. Verifies the caller's JWT (Authorization header) and looks up their
   `public.users` row.
2. Requires `role IN ('owner', 'admin', 'instructor')`.
3. Confirms the target email exists in `public.whitelist`.
4. Calls `auth.admin.generateLink({type: 'magiclink', email, options: {redirectTo}})`.
5. If the email is brand-new in `auth.users`, falls back to
   `auth.admin.inviteUserByEmail(email)` so first-time invites still work.

Either path sends a clickable email via the project's configured SMTP (Resend).

### Why `--no-verify-jwt`

The default Supabase function gateway rejects requests with no JWT, but we
also need the caller's role from `public.users` and the function logs which
admin sent which invite. So we extract the JWT ourselves and call
`auth.getUser(jwt)`. Deploying with `--no-verify-jwt` lets us own that path
end-to-end (still authenticated — just by us, not by the gateway).

---

## One-time setup

```bash
# 1. Install the Supabase CLI (Homebrew on macOS).
brew install supabase/tap/supabase

# 2. Log in (opens a browser; one-off per machine).
supabase login

# 3. Link this repo to the project.
cd /path/to/mybjj-app
supabase link --project-ref dcilltzgegqsrgatskhz
```

### Secrets

**You don't need to set `SUPABASE_SERVICE_ROLE_KEY` manually.** It (and
`SUPABASE_URL`) are auto-injected into every Edge Function's environment. The
spec in the design doc was overcautious — `supabase secrets set
SERVICE_ROLE_KEY=…` is unnecessary.

If you need to override the redirect for staging, set `MYBJJ_REDIRECT_TO`:
```bash
supabase secrets set MYBJJ_REDIRECT_TO=https://staging.mybjj-app.com
```
(Currently the function defaults to `https://mybjj-app.com` if the request
body doesn't supply a `redirectTo`. The frontend always supplies one.)

---

## Deploy

```bash
supabase functions deploy send-magic-link --no-verify-jwt
```

Watch for `Function deployed successfully`. The URL will be:

```
https://dcilltzgegqsrgatskhz.supabase.co/functions/v1/send-magic-link
```

---

## Smoke test from a terminal

```bash
# 1. Grab an access_token for an owner/professor/coach user by signing in
#    via the app, then in the browser console:
#      (await sb.auth.getSession()).data.session.access_token
JWT='paste-here'

# 2. Hit the function.
curl -i -X POST \
  https://dcilltzgegqsrgatskhz.supabase.co/functions/v1/send-magic-link \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"email":"someone@whitelisted.example"}'
```

Expected: `HTTP/2 200` and `{"ok":true}`. The whitelisted address should
receive an email within ~1 minute.

---

## Operating notes

- **Logs.** `supabase functions logs send-magic-link --tail` streams them, or
  use the Supabase dashboard → Functions → send-magic-link → Logs.
- **Redeploy** after editing `index.ts`: `supabase functions deploy
  send-magic-link --no-verify-jwt` again. Each deploy creates a new
  immutable version.
- **Rotating the service role key.** Done from Supabase dashboard → Project
  Settings → API. The function auto-picks up the new key on next cold start;
  no redeploy needed.
- **Removing the function.** `supabase functions delete send-magic-link`.
- **Local dev.** `supabase functions serve send-magic-link --env-file
  ./supabase/.env.local`, then POST to `http://localhost:54321/functions/v1/send-magic-link`.

---

## Error responses

| HTTP | `error` value                 | When                                              | Frontend mapping                                                |
|------|-------------------------------|---------------------------------------------------|-----------------------------------------------------------------|
| 401  | `Not authenticated`           | Missing / invalid JWT                             | Generic "You're signed out" prompt                              |
| 403  | `Not authorized`              | Caller is a student / parent                      | "You don't have permission to do that."                         |
| 400  | `Invalid email`               | Malformed payload                                  | "Please enter a valid email address."                           |
| 400  | `Email not in whitelist`      | Target not in `public.whitelist`                  | "This email isn't authorized yet. Save the email first."        |
| 429  | `Rate limit exceeded`         | Supabase throttled the address                    | "Too many invites sent recently. Please wait a few minutes."    |
| 500  | `Server not configured`       | Env vars missing                                  | "Connection issue. Please try again."                           |
| 500  | (other generateLink message)  | Supabase auth API surfaced a different error     | "Something went wrong. Please try again."                       |
