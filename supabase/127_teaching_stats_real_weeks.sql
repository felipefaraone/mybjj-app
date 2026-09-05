-- ============================================================================
-- 127 — teaching_stats: measure weeks from the data, not from the window
-- ============================================================================
-- The Teaching card divides classes taught by a week count that was always
-- 52.1, because p_since is always twelve months back regardless of when the
-- data actually starts:
--
--   greatest((current_date - p_since)::numeric / 7.0, 1) as weeks
--
-- The head instructor's first recorded class inside the window is early June.
-- Over 14.4 real weeks he taught 127 classes. The card showed 2.4 a week and he
-- teaches most days, several a day. A number that wrong on a card he opens
-- often is worse than no number at all.
--
-- The student side of the app already solved this: _monthlyPace is documented as
-- period-partial-safe and is the single source of pace there. Teaching was born
-- with its own arithmetic in Postgres and never inherited the protection — the
-- same question answered in two places, which is the shape of most of the bugs
-- found on 5 September.
--
-- The window stays twelve months: that is what the label says. Only the divisor
-- changes, anchored to the first class actually inside the window. A teacher
-- with a full year of data is unaffected, since their first class sits at or
-- near p_since and the two spans converge. An empty set falls back to the full
-- window, so the divisor is never zero and never negative.
--
-- Superseded in part by migration 128, which fixes WHICH classes are counted.
-- The divisor logic here is unchanged by it.
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
  -- guard: caller can only read their OWN teaching stats
  if p_staff_id is null
     or p_staff_id <> (select s.id from public.staff s where s.user_id = auth.uid()) then
    raise exception 'Not authorized to read these teaching stats' using errcode = '42501';
  end if;

  return query
  with aulas as (
    select distinct a.class_date, a.class_id, c.uniform
    from public.attendance a
    join public.classes c on c.id = a.class_id
    where c.instructor_id = p_staff_id
      and a.class_date >= p_since
  ),
  agg as (
    select
      count(*)::int as taught,
      count(*) filter (where uniform='Gi')::int as gi,
      count(*) filter (where uniform='No-Gi')::int as nogi,
      count(*) filter (where uniform not in ('Gi','No-Gi') or uniform is null)::int as mixed,
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
