-- 45_phase8_class_value_5tier.sql
-- Adds attendance.class_value for 5-tier marking (Phase 2 UI).
-- Adds students.last_marker_date (cached for months calc).
-- Updates recompute_student_stats to use SUM(class_value).

ALTER TABLE public.attendance
  ADD COLUMN IF NOT EXISTS class_value numeric(3,2) NOT NULL DEFAULT 1.00;

COMMENT ON COLUMN public.attendance.class_value IS
  'Counted value for promotion stats. 2.00=signature+circle, 1.00=signature, 0.50=circle, 0.25=tick, 0.00=X. Default 1.00 matches legacy COUNT.';

ALTER TABLE public.students
  ADD COLUMN IF NOT EXISTS last_marker_date date;

COMMENT ON COLUMN public.students.last_marker_date IS
  'Date of most recent promotion event (stripe or belt). NULL if none yet. Used to compute months_since_last_marker for eligibility checks.';

-- Defensive: absent rows should not count
UPDATE public.attendance
SET class_value = 0.00
WHERE status = 'absent' AND class_value <> 0.00;

-- Update recompute_student_stats: SUM(class_value), cache last_marker_date
CREATE OR REPLACE FUNCTION public.recompute_student_stats(p_student_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    total = v_total::integer,
    gi_classes = v_gi::integer,
    nogi_classes = v_nogi::integer,
    grade = v_grade::integer,
    gi_grade = v_gi_grade::integer,
    last_marker_date = v_last_marker_date
  WHERE id = p_student_id;
END;
$$;

-- Re-backfill all active students
DO $$
DECLARE
  s_id uuid;
BEGIN
  FOR s_id IN SELECT id FROM public.students WHERE active = true LOOP
    PERFORM public.recompute_student_stats(s_id);
  END LOOP;
END $$;

-- Verify
DO $$
DECLARE
  col_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'attendance' AND column_name = 'class_value'
  ) INTO col_exists;
  IF NOT col_exists THEN RAISE EXCEPTION 'class_value not created'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'students' AND column_name = 'last_marker_date'
  ) INTO col_exists;
  IF NOT col_exists THEN RAISE EXCEPTION 'last_marker_date not created'; END IF;

  RAISE NOTICE 'Migration 45 applied ✓';
END $$;
