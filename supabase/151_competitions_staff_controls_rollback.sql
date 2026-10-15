-- 151_competitions_staff_controls_rollback.sql
--
-- Undo 151: put competition_standings and competition_unit_battle back exactly
-- as 149 defines them, and drop competition_rules_for_date. Drops no data.

begin;

drop function if exists public.competition_rules_for_date(uuid, date);

create or replace function public.competition_standings(p_competition uuid, p_from date default null, p_to date default null)
returns table (
  division_id        uuid,
  unit_id            uuid,
  audience           text,
  student_id         uuid,
  display_name       text,
  photo_url          text,
  points             numeric,
  class_points       numeric,
  gi_points          numeric,
  nogi_points        numeric,
  award_points       numeric,
  referral_points    numeric,
  classes_count      integer,
  last_scored_on     date,
  prize_eligible     boolean,
  leaderboard_hidden boolean,
  rank               integer,
  prize_rank         integer,
  belt               text,
  degree             integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff boolean := coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false);
  v_mine  uuid[];   -- the caller's own students rows and their guardian kids
begin
  if coalesce(public.current_status(), '') <> 'approved' then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_mine := array(select s.id from public.students s where s.user_id = auth.uid())
            || coalesce(public.guardian_student_ids(), array[]::uuid[]);
  return query
    select r.*
      from public._competition_ranked(p_competition, p_from, p_to) r
     where (r.audience = 'adult'
            or v_staff
            or exists (select 1 from public.students k
                        where k.id = any (v_mine)
                          and k.unit_id = r.unit_id
                          and public._competition_audience(k.prog::text) = 'kids'))
       and (r.leaderboard_hidden is not true
            or v_staff
            or r.student_id = any (v_mine))
     order by r.audience, r.unit_id, r.rank, r.display_name, r.student_id;
end;
$$;

create or replace function public.competition_unit_battle(p_competition uuid, p_from date default null, p_to date default null)
returns table (
  unit_id         uuid,
  unit_name       text,
  audience        text,
  active_students integer,
  total_classes   integer,
  avg_classes     numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_status(), '') <> 'approved' then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return query
    select s.unit_id,
           u.name::text,
           s.audience,
           (count(*) filter (where s.classes_count > 0))::integer,
           coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0)::integer,
           case when count(*) filter (where s.classes_count > 0) = 0 then 0::numeric
                else (coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0))::numeric
                     / (count(*) filter (where s.classes_count > 0))::numeric
           end
      from public._competition_scores(p_competition, p_from, p_to) s
      left join public.units u on u.id = s.unit_id
     group by s.unit_id, u.name, s.audience
     order by s.audience, u.name, s.unit_id;
end;
$$;

revoke all on function public.competition_standings(uuid, date, date)   from public, anon;
grant execute on function public.competition_standings(uuid, date, date)   to authenticated;
revoke all on function public.competition_unit_battle(uuid, date, date) from public, anon;
grant execute on function public.competition_unit_battle(uuid, date, date) to authenticated;

commit;
