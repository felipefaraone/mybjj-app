-- Migration 49 — Profile fields restructure for G16a.
-- Adds first_name / last_name (split out from full_name), has_mybjj_gi
-- toggle, and social_handles jsonb to both public.students and public.staff.
-- Backfills first_name / last_name from existing full_name (split on
-- first whitespace; single-name rows → last_name = '').
-- Updates edit_student_self RPC to accept the four new keys so self
-- edits via the new Edit Profile modal land cleanly without a fallback.

BEGIN;

-- 1. New columns on students.
ALTER TABLE public.students
  ADD COLUMN IF NOT EXISTS first_name     text,
  ADD COLUMN IF NOT EXISTS last_name      text,
  ADD COLUMN IF NOT EXISTS has_mybjj_gi   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS social_handles jsonb   NOT NULL DEFAULT '{}'::jsonb;

-- 2. Same on staff (staff edit UI lands in a later batch but the columns
--    are ready so the schema doesn't drift between roles).
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS first_name     text,
  ADD COLUMN IF NOT EXISTS last_name      text,
  ADD COLUMN IF NOT EXISTS has_mybjj_gi   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS social_handles jsonb   NOT NULL DEFAULT '{}'::jsonb;

-- 3. Backfill first_name / last_name from full_name. Splits on the
--    first whitespace; rows with no whitespace land first_name =
--    full_name, last_name = ''. Only runs where first_name is still
--    null so re-applying the migration is a no-op.
UPDATE public.students
   SET first_name = CASE
         WHEN full_name IS NULL OR btrim(full_name) = '' THEN NULL
         WHEN position(' ' in btrim(full_name)) = 0 THEN btrim(full_name)
         ELSE substr(btrim(full_name), 1, position(' ' in btrim(full_name)) - 1)
       END,
       last_name = CASE
         WHEN full_name IS NULL OR btrim(full_name) = '' THEN ''
         WHEN position(' ' in btrim(full_name)) = 0 THEN ''
         ELSE btrim(substr(btrim(full_name), position(' ' in btrim(full_name)) + 1))
       END
 WHERE first_name IS NULL;

UPDATE public.staff
   SET first_name = CASE
         WHEN full_name IS NULL OR btrim(full_name) = '' THEN NULL
         WHEN position(' ' in btrim(full_name)) = 0 THEN btrim(full_name)
         ELSE substr(btrim(full_name), 1, position(' ' in btrim(full_name)) - 1)
       END,
       last_name = CASE
         WHEN full_name IS NULL OR btrim(full_name) = '' THEN ''
         WHEN position(' ' in btrim(full_name)) = 0 THEN ''
         ELSE btrim(substr(btrim(full_name), position(' ' in btrim(full_name)) + 1))
       END
 WHERE first_name IS NULL;

-- 4. edit_student_self RPC — accept the four new keys. Pattern matches
--    migration 44's structure: each allowed key is folded into the
--    UPDATE via COALESCE / CASE WHEN payload ? 'key'. Belt / degree /
--    journey / feedback / counters remain admin-only.
CREATE OR REPLACE FUNCTION public.edit_student_self(
  p_legacy_id text,
  p_payload   jsonb
)
RETURNS public.students
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target_id uuid;
  result    public.students;
BEGIN
  SELECT s.id INTO target_id
    FROM public.students s
   WHERE s.legacy_id = p_legacy_id
     AND (s.user_id = auth.uid() OR s.parent_user_id = auth.uid())
     AND s.active = true;

  IF target_id IS NULL THEN
    RAISE EXCEPTION 'Not authorized to edit this student profile' USING ERRCODE = '42501';
  END IF;

  UPDATE public.students
     SET
       full_name               = COALESCE(p_payload->>'full_name', full_name),
       first_name              = COALESCE(p_payload->>'first_name', first_name),
       last_name               = COALESCE(p_payload->>'last_name',  last_name),
       initials                = COALESCE(p_payload->>'initials', initials),
       date_of_birth           = COALESCE((p_payload->>'date_of_birth')::date, date_of_birth),
       phone                   = COALESCE(p_payload->>'phone', phone),
       gender                  = COALESCE(p_payload->>'gender', gender),
       weight_kg               = CASE WHEN p_payload ? 'weight_kg' THEN (p_payload->>'weight_kg')::integer ELSE weight_kg END,
       height_cm               = CASE WHEN p_payload ? 'height_cm' THEN (p_payload->>'height_cm')::integer ELSE height_cm END,
       emergency_contact_name  = COALESCE(p_payload->>'emergency_contact_name', emergency_contact_name),
       emergency_contact_phone = COALESCE(p_payload->>'emergency_contact_phone', emergency_contact_phone),
       has_mybjj_gi            = CASE WHEN p_payload ? 'has_mybjj_gi' THEN (p_payload->>'has_mybjj_gi')::boolean ELSE has_mybjj_gi END,
       social_handles          = CASE WHEN p_payload ? 'social_handles' THEN (p_payload->'social_handles') ELSE social_handles END
   WHERE id = target_id
   RETURNING * INTO result;

  RETURN result;
END;
$$;

-- Verification
DO $$
DECLARE
  v_students_with_first int;
  v_staff_with_first    int;
BEGIN
  SELECT count(*) INTO v_students_with_first FROM public.students WHERE first_name IS NOT NULL;
  SELECT count(*) INTO v_staff_with_first    FROM public.staff    WHERE first_name IS NOT NULL;
  RAISE NOTICE 'Migration 49: students first_name populated for % rows; staff first_name populated for % rows', v_students_with_first, v_staff_with_first;
END $$;

COMMIT;
