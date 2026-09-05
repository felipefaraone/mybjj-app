-- ============================================================================
-- 126 — get_class_history counts DAYS, and skips declared promotions
-- ============================================================================
-- Two numbers answered "classes since your last grading" and disagreed. The
-- eligibility counter reads students.grade, which counts one credit per
-- training DAY (the owner's rule since 2026-07-31). Belt by belt, rendered
-- immediately below it, summed every attendance ROW.
--
-- A student with 19 attendances over 16 training days saw one number in each
-- box. The head instructor read them on different days, across three students,
-- and concluded the app had silently moved his numbers. It had not — but the
-- two boxes had never agreed, so there was no way for him to tell.
--
-- Asked directly which one was right, he said: days.
--
-- THE SPLIT STAYS IN CLASSES
--
-- A day with both a Gi and a No-Gi session is one credit, and there is no rule
-- for which modality earns it. Inventing that rule is a product decision the
-- academy has never made, so it is not made here. The headline is days and the
-- split is classes, which means they cannot be expected to sum — so
-- has_full_split is false on every period derived from attendance, and the UI
-- hides the split exactly as it already does whenever the parts do not add up.
--
-- The one exception is a closed period whose count was stored on the promotion
-- that closed it: that value is historical, both parts are classes, and it is
-- returned untouched.
--
-- THE FIFTH PLACE THAT HAD TO LEARN ABOUT source='declared'
--
-- Migration 123 named three functions that must skip declared rows so a
-- student's own account of their pre-app past cannot move the grading clock.
-- 124 found a fourth (update_class_counts). This is the fifth: both the marker
-- count and the period loop took every promotion. Only one student holds
-- declared rows today, so this is prevention, not repair — but the pattern is
-- now unmistakable, and any new function that reads promotions should be
-- checked for it.
-- ============================================================================

create or replace function public.get_class_history(p_student_id uuid)
 returns jsonb
 language plpgsql
 stable
as $function$
declare
  v_baseline_grade numeric;
  v_result jsonb := '[]'::jsonb;
  v_m record;
  v_classes numeric;
  v_gi numeric;
  v_nogi numeric;
  v_is_current boolean;
  v_has_split boolean;
  v_marker_count int;
begin
  select coalesce(baseline_grade,0) into v_baseline_grade
  from public.students where id = p_student_id;

  select count(*) into v_marker_count
  from public.promotions
  where student_id = p_student_id
    and coalesce(source,'academy') = 'academy';

  if v_marker_count = 0 then
    -- No marker: the whole life so far. DAYS for the headline, classes for split.
    select coalesce(sum(day_max),0) into v_classes
    from (
      select class_date, max(class_value) as day_max
      from public.attendance
      where student_id = p_student_id and status='present'
      group by class_date
    ) daily;

    select
      coalesce(sum(class_value) filter (where modality='gi'),0),
      coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
    into v_gi, v_nogi
    from public.attendance
    where student_id = p_student_id and status='present';

    return jsonb_build_array(jsonb_build_object(
      'belt', (select belt from public.students where id=p_student_id),
      'deg',  (select degree from public.students where id=p_student_id),
      'from_date', null, 'to_date', null, 'is_current', true,
      'classes', v_classes + v_baseline_grade,
      'gi', v_gi, 'nogi', v_nogi,
      'has_full_split', false
    ));
  end if;

  for v_m in
    select p.date as marker_date, p.to_belt, p.to_deg, p.type,
           lead(p.date)    over (order by p.date) as next_date,
           lead(p.classes) over (order by p.date) as next_classes,
           lead(p.gi)      over (order by p.date) as next_gi,
           lead(p.nogi)    over (order by p.date) as next_nogi
    from public.promotions p
    where p.student_id = p_student_id
      and coalesce(p.source,'academy') = 'academy'
    order by p.date
  loop
    v_is_current := (v_m.next_date is null);

    if v_is_current then
      -- Open period: marker to today. baseline_grade (pre-app history not yet
      -- consumed by any promotion) belongs to this period.
      select coalesce(sum(day_max),0) into v_classes
      from (
        select class_date, max(class_value) as day_max
        from public.attendance
        where student_id = p_student_id and status='present'
          and class_date > v_m.marker_date
        group by class_date
      ) daily;

      select
        coalesce(sum(class_value) filter (where modality='gi'),0),
        coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
      into v_gi, v_nogi
      from public.attendance
      where student_id = p_student_id and status='present'
        and class_date > v_m.marker_date;

      v_classes := v_classes + v_baseline_grade;
      v_has_split := false;

    elsif v_m.next_classes is not null then
      -- Closed period with the count stored on the promotion that closed it.
      -- Historical, both parts in classes, returned untouched.
      v_classes := v_m.next_classes;
      v_gi   := coalesce(v_m.next_gi,0);
      v_nogi := coalesce(v_m.next_nogi,0);
      v_has_split := (v_m.next_gi is not null and v_m.next_nogi is not null);

    else
      -- Closed period with no stored count: derive from real attendance
      -- between this marker and the next.
      select coalesce(sum(day_max),0) into v_classes
      from (
        select class_date, max(class_value) as day_max
        from public.attendance
        where student_id = p_student_id and status='present'
          and class_date > v_m.marker_date
          and class_date <= v_m.next_date
        group by class_date
      ) daily;

      select
        coalesce(sum(class_value) filter (where modality='gi'),0),
        coalesce(sum(class_value) filter (where modality in ('nogi','mma')),0)
      into v_gi, v_nogi
      from public.attendance
      where student_id = p_student_id and status='present'
        and class_date > v_m.marker_date
        and class_date <= v_m.next_date;

      v_has_split := false;
    end if;

    v_result := v_result || jsonb_build_object(
      'belt', v_m.to_belt,
      'deg',  v_m.to_deg,
      'type', v_m.type,
      'from_date', v_m.marker_date,
      'to_date',   v_m.next_date,
      'is_current', v_is_current,
      'classes', v_classes,
      'gi', v_gi, 'nogi', v_nogi,
      'has_full_split', v_has_split
    );
  end loop;

  return v_result;
end;
$function$;
