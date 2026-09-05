-- ============================================================================
-- 124 — update_class_counts: count DAYS, and ignore declared promotions
-- ============================================================================
-- Two bugs, both in the same function, both invisible until someone typed a
-- number and got a different one back.
--
-- 1. THE FIELD LIED ABOUT ITS OWN ARITHMETIC.
--    The modal sends a TARGET; the function stores target minus real, and
--    recompute_student_stats derives the display value back as baseline + real.
--    For that round trip to be honest, both sides must measure "real" the same
--    way. They did not. recompute counts one credit per training DAY
--    (SUM(MAX(class_value)) grouped by class_date, the owner's rule since
--    2026-07-31); this function counted every attendance ROW.
--
--    For a student with 19 attendances over 16 days, typing 20 stored a
--    baseline of max(20-19,0)=1 and recompute produced 17. The professor would
--    have typed 20, seen 17, and typed again. It only looked correct on a no-op
--    save, and only because greatest(...,0) clipped the negative.
--
--    105 active students have more attendances than training days, so the error
--    was one to eleven credits depending on the student.
--
-- 2. THE FOURTH PLACE THAT HAD TO LEARN ABOUT source='declared'.
--    Migration 123 named three functions that must skip declared rows so a
--    student's own account of their pre-app history cannot move the grading
--    clock. This was a fourth, and it was missed: its MAX(date) took every
--    promotion. A declared belt could set v_last_marker here to a date
--    recompute_student_stats does not use, so the baseline would be computed
--    against one cutoff and displayed against another.
--
-- Behaviour change, intended: the number typed is now the number that appears.
-- Existing baselines are NOT touched. A row written by the old arithmetic keeps
-- its value until someone reopens and saves that student. 26 active students
-- have both a non-zero baseline_grade and at least one double day; they need a
-- human pass, tracked separately.
-- ============================================================================

create or replace function public.update_class_counts(
  p_legacy_id text, p_total numeric, p_gi numeric, p_nogi numeric,
  p_grade numeric, p_gi_grade numeric)
 returns students
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_belt text; v_student public.students; v_id uuid; v_last_marker date;
  v_real_total numeric; v_real_grade numeric;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_total<0 or p_grade<0 then
    raise exception 'counters must be non-negative';
  end if;

  if not public.is_unit_owner_any() then
    if not public.is_staff() then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
    select s.belt into v_belt from public.staff s where s.user_id = auth.uid() limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
  end if;

  select id into v_id from public.students where legacy_id = p_legacy_id;
  if v_id is null then raise exception 'student % not found', p_legacy_id; end if;

  -- FIX 2 — academy only, mirroring recompute_student_stats. A declared belt is
  -- the student's own account of what happened before the app and must never
  -- move the grading clock.
  select max(date) into v_last_marker
    from public.promotions
   where student_id = v_id
     and coalesce(source,'academy') = 'academy';

  -- Lifetime total is a plain sum in both functions — unchanged.
  select coalesce(sum(class_value),0) into v_real_total
    from public.attendance where student_id=v_id and status='present';

  -- FIX 1 — one credit per training DAY, the same shape recompute uses. Any
  -- other shape here makes the typed number and the displayed number disagree.
  select coalesce(sum(day_max),0) into v_real_grade
  from (
    select class_date, max(class_value) as day_max
      from public.attendance
     where student_id=v_id and status='present'
       and (v_last_marker is null or class_date > v_last_marker)
     group by class_date
  ) daily;

  update public.students set
    baseline_total = greatest(p_total  - v_real_total, 0),
    baseline_grade = greatest(p_grade  - v_real_grade, 0)
  where id = v_id;

  perform public.recompute_student_stats(v_id);

  select * into v_student from public.students where id = v_id;
  return v_student;
end;
$function$;
