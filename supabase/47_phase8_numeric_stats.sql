-- Migration 47 — Stats columns become numeric(5,2) for fractional accuracy.
-- Recompute function rewritten to NOT cast to integer. Re-allows the
-- 'absent' status that migration 35 had removed — back now as an
-- explicit communication signal (not a soft-delete), excluded from
-- recompute_student_stats sums by the existing WHERE status='present'
-- clause. Backfills all students by re-running recompute.

BEGIN;

-- 1. Migrate columns. Existing integer values cast cleanly (5 → 5.00).
ALTER TABLE public.students
  ALTER COLUMN total TYPE numeric(5,2) USING total::numeric(5,2),
  ALTER COLUMN grade TYPE numeric(5,2) USING grade::numeric(5,2),
  ALTER COLUMN gi_classes TYPE numeric(5,2) USING gi_classes::numeric(5,2),
  ALTER COLUMN nogi_classes TYPE numeric(5,2) USING nogi_classes::numeric(5,2),
  ALTER COLUMN gi_grade TYPE numeric(5,2) USING gi_grade::numeric(5,2);

-- 2. Recompute function — drop integer cast.
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
  WHERE student_id = p_student_id AND status = 'present' AND class_type = 'gi';

  SELECT COALESCE(SUM(class_value), 0) INTO v_nogi
  FROM public.attendance
  WHERE student_id = p_student_id AND status = 'present' AND class_type = 'nogi';

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
    AND class_type = 'gi'
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

-- 3. Backfill all students (re-runs recompute, applies precise numeric sums).
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
  RAISE NOTICE 'Migration 47: recomputed % students with precise numeric sums', cnt;
END $$;

-- 4. Re-allow 'absent' (migration 35 had removed it; G9.3 brings it back
--    as an explicit disambiguation signal — "instructor forgot to mark
--    me" disputes are resolved by an explicit ABSENT row instead of an
--    ambiguous lingering 'going'). 'absent' is intentionally excluded
--    from recompute_student_stats sums by the existing
--    WHERE status='present' clauses, so this is purely a constraint
--    relaxation, not a stat-accounting change.
ALTER TABLE public.attendance
  DROP CONSTRAINT IF EXISTS attendance_status_check;

ALTER TABLE public.attendance
  ADD CONSTRAINT attendance_status_check
  CHECK (status IN ('going','present','absent'));

COMMIT;
