-- ============================================================================
-- 128 — teaching_stats: who TAUGHT, not who is on the template
-- ============================================================================
-- The card counted classes.instructor_id, which is the weekly template: who is
-- SCHEDULED to teach, not who taught. When someone covers a class the app
-- records it in class_exceptions.substitute_instructor_id, and the schema doc
-- is explicit about it — "who taught" lives on the exception, not on
-- attendance. (The confirmed_by_instructor_id column that a spec once proposed
-- was never used and is 100% null across 4552 attendance rows.)
--
-- So the number missed every class the instructor actually covered for someone
-- else, and would have counted classes he was covered for. For the head
-- instructor over twelve months: 127 on the template, 0 covered by others, 26
-- covered by him — 152 once the union drops the one day he is both.
--
-- 110 overrides exist since 14 August, every one of them with a substitute.
-- This is daily use, not an edge case.
--
-- A class the instructor covered counts even if nobody marked attendance that
-- day: the override row is the academy's own record that he took it, and the
-- absence of a check-in says something about the students, not about him.
--
-- Together with 127 the card now answers the question it asks: classes this
-- person taught, over the weeks they were teaching. It went from 2.4 a week to
-- 10.5 for someone who teaches most days.
-- ============================================================================

create or replace function public.teaching_stats(p_staff_id uuid, p_since date)
 returns table(taught integer, gi integer, nogi integer, mixed integer,
               weeks numeric, weekly numeric)
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
begin
  if p_staff_id is null
     or p_staff_id <> (select s.id from public.staff s where s.user_id = auth.uid()) then
    raise exception 'Not authorized to read these teaching stats' using errcode = '42501';
  end if;

  return query
  with aulas as (
    -- Scheduled to teach it, and nobody else covered that day.
    select distinct a.class_date, a.class_id, c.uniform
    from public.attendance a
    join public.classes c on c.id = a.class_id
    where c.instructor_id = p_staff_id
      and a.class_date >= p_since
      and not exists (
        select 1 from public.class_exceptions e
         where e.kind = 'instructor_override'
           and e.class_id = a.class_id
           and e.exception_date = a.class_date
           and e.substitute_instructor_id is distinct from p_staff_id)

    union

    -- Covered someone else's class. UNION, not UNION ALL: being both the
    -- template instructor and the recorded substitute on the same day is one
    -- class, not two.
    select distinct e.exception_date as class_date, e.class_id, c.uniform
    from public.class_exceptions e
    join public.classes c on c.id = e.class_id
    where e.kind = 'instructor_override'
      and e.substitute_instructor_id = p_staff_id
      and e.exception_date >= p_since
  ),
  agg as (
    select
      count(*)::int as taught,
      count(*) filter (where uniform='Gi')::int as gi,
      count(*) filter (where uniform='No-Gi')::int as nogi,
      count(*) filter (where uniform not in ('Gi','No-Gi') or uniform is null)::int as mixed,
      -- Divisor anchored on the first class inside the window (migration 127).
      greatest(
        (current_date - coalesce(min(class_date), p_since))::numeric / 7.0,
        1
      ) as weeks
    from aulas
  )
  select a.taught, a.gi, a.nogi, a.mixed, round(a.weeks,1), round(a.taught / a.weeks, 1)
  from agg a;
end;
$function$;
