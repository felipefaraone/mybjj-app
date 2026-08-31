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

-- Trigger captured from the live DB (never committed): zeroes baseline_grade for
-- the affected student on promotion INSERT/DELETE, then recomputes.
CREATE OR REPLACE FUNCTION public.promotion_reset_grade_baseline()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  update public.students set baseline_grade = 0
   where id = coalesce(NEW.student_id, OLD.student_id);
  perform public.recompute_student_stats(coalesce(NEW.student_id, OLD.student_id));
  return coalesce(NEW, OLD);
end;
$function$;
DROP TRIGGER IF EXISTS trg_promotion_reset_grade_baseline ON public.promotions;
CREATE TRIGGER trg_promotion_reset_grade_baseline
AFTER INSERT OR DELETE ON public.promotions
FOR EACH ROW EXECUTE FUNCTION public.promotion_reset_grade_baseline();

-- Trigger captured from the live DB (never committed): notifies the student
-- (or parent) on every promotion INSERT. NOTE: it does not check NEW.hidden —
-- historical entries made via the Promote->"not current belt" flow also notify.
CREATE OR REPLACE FUNCTION public.trg_notify_promotion_fn()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_user_id       uuid;
  v_student_name  text;
  v_student_prog  text;
  v_promoter_name text;
  v_title         text;
  v_body          text;
begin
  select coalesce(s.user_id, s.parent_user_id), s.full_name, s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s where s.id = NEW.student_id;
  if v_user_id is null then return NEW; end if;
  v_promoter_name := coalesce(NEW.promoted_by_name, 'Your instructor');
  if NEW.is_new_belt is true then
    v_title := 'New belt!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    else
      v_body := 'You were promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    end if;
  else
    v_title := 'New stripe!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' earned a new stripe from ' || v_promoter_name || '.';
    else
      v_body := 'You earned a new stripe from ' || v_promoter_name || '.';
    end if;
  end if;
  perform public.create_notification(
    p_user_id := v_user_id, p_type := 'promotion', p_title := v_title, p_body := v_body,
    p_related_entity_type := 'promotion', p_related_entity_id := NEW.id,
    p_metadata := jsonb_build_object('student_id', NEW.student_id, 'from_belt', NEW.from_belt,
      'to_belt', NEW.to_belt, 'from_deg', NEW.from_deg, 'to_deg', NEW.to_deg, 'is_new_belt', NEW.is_new_belt),
    p_check_prefs := true);
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS trg_notify_promotion ON public.promotions;
CREATE TRIGGER trg_notify_promotion
AFTER INSERT ON public.promotions
FOR EACH ROW EXECUTE FUNCTION public.trg_notify_promotion_fn();
