# Supabase configuration for myBJJ

This file documents the manual dashboard steps that aren't captured in
the SQL migrations. Run the SQL migrations in numeric order
(`01_schema.sql` → `21_phase8_journey_label_fix.sql`) first, then walk
through the items below.

Project ref: **`dcilltzgegqsrgatskhz`**.

---

## Authentication providers

### Email + password (Phase 9)

`Authentication → Providers → Email`

| Setting | Value |
| --- | --- |
| **Enable email provider** | on |
| **Allow new users to sign up with password** | on |
| **Confirm email** | off (whitelist already gates who can sign in) |
| **Secure email change** | on (default) |
| **Secure password change** | on (default) |

### Magic link

Stays on. No additional config beyond the default. Edge Function
`send-magic-link` (see `functions/README.md`) drives the admin-initiated
invites; user-initiated magic links go through `auth.signInWithOtp`.

### Google OAuth

`Authentication → Providers → Google`

- **Enable Google provider** on.
- Client ID / Client Secret from the Google Cloud project. Not stored
  in this repo.
- Authorized redirect URI:
  `https://dcilltzgegqsrgatskhz.supabase.co/auth/v1/callback`.

---

## URL configuration

`Authentication → URL Configuration`

- **Site URL**: `https://mybjj-app.com`
- **Redirect URLs** (whitelist — comma-separated):
  - `https://mybjj-app.com/*`
  - `http://localhost:8080/*` (local dev)

The reset-password and magic-link flows redirect back to the app's
origin; both must be on the redirect whitelist or Supabase rejects the
link with `redirect_to is not allowed`.

---

## Email templates

`Authentication → Email Templates`

| Template | File | Subject |
| --- | --- | --- |
| **Magic Link** | `email_templates/magic_link.html` | `Welcome to myBJJ — sign in` |
| **Reset Password** | `email_templates/password_reset.html` | `Reset your myBJJ password` |

Paste the HTML body verbatim. Supabase substitutes `{{ .ConfirmationURL }}` at send time.

The `Confirm signup` and `Invite user` templates aren't currently used by
the app's flows — the Edge Function calls `signInWithOtp` for new admin
invites, which uses the **Magic Link** template. Leaving the other two
on Supabase defaults is fine.

---

## SMTP

`Authentication → SMTP Settings`

Resend (current provider). API key stored in Supabase — not in this
repo. If we ever rotate, update there.

---

## Edge functions

See `functions/README.md` for `send-magic-link` deploy steps.

---

## Quick verification after configuring

```bash
# Magic link
curl -i -X POST \
  https://dcilltzgegqsrgatskhz.supabase.co/auth/v1/otp \
  -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"email":"<your-whitelisted-email>"}'

# Password reset
curl -i -X POST \
  https://dcilltzgegqsrgatskhz.supabase.co/auth/v1/recover \
  -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"email":"<your-whitelisted-email>"}'
```

Both should return `200` and trigger an email via Resend. Check Resend's
Logs view if a message goes missing.
