-- 111 — Capture what exists ONLY in the live DB (created ad hoc in the SQL editor,
-- never committed): the four baseline columns on students and the live
-- recompute_student_stats that uses them. Without this, a fresh project built
-- from migrations (staging) has no baseline columns and RPCs 104/106 break.
-- Idempotent: safe to run on production (no-op there).

alter table public.students
  add column if not exists baseline_total numeric default 0,
  add column if not exists baseline_grade numeric default 0,
  add column if not exists baseline_gi    numeric default 0,
  add column if not exists baseline_nogi  numeric default 0;

CREATE OR REPLACE FUNCTION public.recompute_student_stats(p_student_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_base_total numeric; v_base_grade numeric;
  v_real_total numeric; v_real_gi numeric; v_real_nogi numeric; v_real_grade numeric;
  v_real_gi_grade numeric; v_real_nogi_grade numeric;
  v_gi numeric; v_nogi numeric; v_total numeric; v_grade numeric;
  v_gi_grade numeric; v_nogi_grade numeric;
  v_last_marker_date date;
BEGIN
  SELECT COALESCE(baseline_total,0), COALESCE(baseline_grade,0)
    INTO v_base_total, v_base_grade
  FROM public.students WHERE id = p_student_id;

  SELECT MAX(date) INTO v_last_marker_date
  FROM public.promotions WHERE student_id = p_student_id;

  -- real attendance totals (LIFE — unchanged, counts every class)
  SELECT COALESCE(SUM(class_value),0) INTO v_real_total
  FROM public.attendance WHERE student_id=p_student_id AND status='present';

  SELECT COALESCE(SUM(class_value),0) INTO v_real_gi
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality='gi';

  SELECT COALESCE(SUM(class_value),0) INTO v_real_nogi
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality IN ('nogi','mma');

  -- real attendance SINCE last promotion — GRADE (belt progression)
  -- 1 training DAY counts as the HIGHEST class_value that day (owner's rule).
  SELECT COALESCE(SUM(day_max),0) INTO v_real_grade
  FROM (
    SELECT class_date, MAX(class_value) AS day_max
    FROM public.attendance
    WHERE student_id=p_student_id AND status='present'
      AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date)
    GROUP BY class_date
  ) daily;

  -- gi/nogi grade split — sum-of-all; the UI hides the split when it doesn't reconcile.
  SELECT COALESCE(SUM(class_value),0) INTO v_real_gi_grade
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality='gi'
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  SELECT COALESCE(SUM(class_value),0) INTO v_real_nogi_grade
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality IN ('nogi','mma')
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  v_gi    := v_real_gi;
  v_nogi  := v_real_nogi;
  v_total := v_base_total + v_real_total;

  v_grade      := v_base_grade + v_real_grade;
  v_gi_grade   := v_real_gi_grade;
  v_nogi_grade := v_real_nogi_grade;

  UPDATE public.students SET
    total=v_total, gi_classes=v_gi, nogi_classes=v_nogi,
    grade=v_grade, gi_grade=v_gi_grade, nogi_grade=v_nogi_grade,
    last_marker_date=v_last_marker_date
  WHERE id=p_student_id;
END;
$function$;
