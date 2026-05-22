-- Migration 54 — Split public.users.full_name into first_name + last_name.
-- B-edit fix: parent self-edit uses two inputs (First name + Last name)
-- to match the students/staff edit pattern. claim_profile returns
-- public.users (full row), so once these columns land the client
-- picks them up via S.profile.first_name / last_name automatically.
-- full_name stays as the canonical display column and is kept in sync
-- on every self-edit (first + ' ' + last) so any consumer reading
-- users.full_name keeps working without changes.
--
-- Idempotent. Backfill only touches rows where both new columns are
-- still NULL, so re-applying after manual edits won't clobber data.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name  text;

UPDATE public.users
   SET first_name = split_part(full_name,' ',1),
       last_name  = NULLIF(regexp_replace(full_name,'^\S+\s*',''),'')
 WHERE full_name IS NOT NULL
   AND first_name IS NULL
   AND last_name  IS NULL;
