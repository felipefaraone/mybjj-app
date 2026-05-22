-- Migration 53 — Add phone column to public.users.
-- B-edit batch: parents self-manage their basic contact details
-- (name + phone) from the profile area. claim_profile returns
-- public.users (full row), so once this column lands the client
-- picks up S.profile.phone automatically.
--
-- Idempotent.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS phone text;
