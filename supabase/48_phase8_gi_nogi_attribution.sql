-- Migration 48 — Gi/No-Gi attribution column on attendance + has_gi drop.
-- Investigation summary: classes have no modality column; modality was
-- encoded in classes.type values (alev/beg/adv/jun = gi; nogi/jnogi = nogi;
-- omat/mma/jmma/mini = neither / "non-traditional BJJ"). Recompute had been
-- filtering by class_type='gi' which never matched anything, so gi_classes
-- and gi_grade were stuck at 0 across the board.
--
-- This migration:
--   1. Adds attendance.modality text NULL with CHECK IN ('gi','nogi').
--   2. Backfills modality from existing class_type values via the locked
--      mapping (omat/mma/jmma/mini stay NULL — they count toward total
--      but not the modality split, per the G13 decision).
--   3. Drops students.has_gi (Felipe's coach-judgment-during-promote
--      decision; preference toggle removed from UI in the same batch).
--   4. Rewrites recompute_student_stats to source gi_classes / gi_grade
--      from attendance.modality instead of class_type.
--   5. Re-runs recompute for every student so the cached stats reflect
--      reality.
--
-- The migration is wrapped in a single transaction so a partial apply
-- can't leave attendance modality unfilled while recompute is running
-- against the new column.

BEGIN;

-- 1. attendance.modality column.
ALTER TABLE public.attendance
  ADD COLUMN IF NOT EXISTS modality text;

ALTER TABLE public.attendance
  DROP CONSTRAINT IF EXISTS attendance_modality_check;

ALTER TABLE public.attendance
  ADD CONSTRAINT attendance_modality_check
  CHECK (modality IS NULL OR modality IN ('gi','nogi'));

-- 2. Backfill from existing class_type. Same map the frontend's CT array
--    carries (index.html ~line 345); kept in sync there for new INSERTs.
UPDATE public.attendance
SET modality = CASE class_type
  WHEN 'alev'  THEN 'gi'
  WHEN 'beg'   THEN 'gi'
  WHEN 'adv'   THEN 'gi'
  WHEN 'jun'   THEN 'gi'
  WHEN 'nogi'  THEN 'nogi'
  WHEN 'jnogi' THEN 'nogi'
  ELSE NULL
END
WHERE modality IS NULL;

-- 3. Drop students.has_gi. Down-stream consumers were the Edit Student
--    "Trains in Gi" toggle (removed in the same commit), the
--    NO-GI ONLY chip (removed), and the GI ACTIVE/REQUIRED pill (logic
--    rewired to read student.gi_classes >= 1).
ALTER TABLE public.students
  DROP COLUMN IF EXISTS has_gi;

-- 4. recompute_student_stats — filter modality buckets via the new column.
--    total / grade stay as SUM(class_value) over all present rows; only
--    the gi / gi_grade buckets change their filter. Rows with NULL
--    modality (omat / mma / jmma / mini) count toward total + grade
--    but contribute to neither modality bucket.
CREATE OR REPLACE FUNCTION public.recompute_student_stats(p_student_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_total numeric;
  v_gi numeric;
  v_nogi numeric;
  v_grade numeric;
  v_gi_grade numeric;
  v_last_marker_date date;
BEGIN
  SELECT COALESCE(SUM(class_value), 0) INTO v_total
  FROM public.attendance
  WHERE student_id = p_student_id AND status = 'present';

  SELECT COALESCE(SUM(class_value), 0) INTO v_gi
  FROM public.attendance
  WHERE student_id = p_student_id AND status = 'present' AND modality = 'gi';

  SELECT COALESCE(SUM(class_value), 0) INTO v_nogi
  FROM public.attendance
  WHERE student_id = p_student_id AND status = 'present' AND modality = 'nogi';

  SELECT MAX(date) INTO v_last_marker_date
  FROM public.promotions
  WHERE student_id = p_student_id;

  SELECT COALESCE(SUM(class_value), 0) INTO v_grade
  FROM public.attendance
  WHERE student_id = p_student_id
    AND status = 'present'
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  SELECT COALESCE(SUM(class_value), 0) INTO v_gi_grade
  FROM public.attendance
  WHERE student_id = p_student_id
    AND status = 'present'
    AND modality = 'gi'
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  UPDATE public.students
  SET
    total = v_total,
    gi_classes = v_gi,
    nogi_classes = v_nogi,
    grade = v_grade,
    gi_grade = v_gi_grade,
    last_marker_date = v_last_marker_date
  WHERE id = p_student_id;
END;
$function$;

-- 5. Re-run recompute across every student so the cached stats catch up
--    with the corrected gi/no-gi bucketing.
DO $$
DECLARE
  r record;
  cnt int := 0;
BEGIN
  FOR r IN SELECT id FROM public.students
  LOOP
    PERFORM public.recompute_student_stats(r.id);
    cnt := cnt + 1;
  END LOOP;
  RAISE NOTICE 'Migration 48: recomputed % students with modality-based gi/nogi attribution', cnt;
END $$;

-- Verification
DO $$
DECLARE
  v_total_att int;
  v_gi_att int;
  v_nogi_att int;
  v_null_att int;
BEGIN
  SELECT count(*) INTO v_total_att FROM public.attendance;
  SELECT count(*) INTO v_gi_att    FROM public.attendance WHERE modality='gi';
  SELECT count(*) INTO v_nogi_att  FROM public.attendance WHERE modality='nogi';
  SELECT count(*) INTO v_null_att  FROM public.attendance WHERE modality IS NULL;
  RAISE NOTICE 'Migration 48: attendance rows total=% gi=% nogi=% null=%',
    v_total_att, v_gi_att, v_nogi_att, v_null_att;
END $$;

COMMIT;
