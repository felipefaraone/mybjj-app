-- ============================================================================
-- 151 — Competitions, PHASE B: staff controls support
-- ============================================================================
--
-- 1. competition_rules_for_date(unit, date): the rules of the competition that
--    applies to a unit on a date (for the class-roster award toggles and the
--    social-post row). An admin also sees a DRAFT event covering the date, so the
--    owner can test the Christmas Cup controls before it goes active; everyone
--    else gets exactly what competition_for_date would show.
-- 2. Close the draft gap: competition_standings and competition_unit_battle
--    return no rows for a 'draft' competition unless the caller is_admin().
--    Both are 149's text with only that early return added (marked "151").
--
-- Requires 148 and 149. No table, column or policy changes.
-- Rollback: 151_competitions_staff_controls_rollback.sql (puts 149's two
-- functions back exactly and drops competition_rules_for_date).
-- Checks:   151_competitions_staff_controls_verify.sql.
-- ============================================================================

begin;

-- The rules of the competition that applies to a unit on a date, for the staff
-- controls (class challenge / attitude toggles, social posts). Same selection as
-- competition_for_date (an active event covering the date through its finale,
-- with a division for the unit; else the active monthly race), except that for an
-- is_admin() caller a DRAFT event covering the date takes the monthly race's place
-- (so the owner can see and test a draft's controls). Staff or admin only.
create or replace function public.competition_rules_for_date(p_unit uuid, p_date date)
returns table (
  competition_id   uuid,
  competition_name text,
  status           text,
  rule_key         text,
  points           numeric,
  enabled          boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_comp uuid;
begin
  if not (coalesce(public.is_staff(), false) or coalesce(public.is_admin(), false)) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select c.id into v_comp
    from public.competitions c
   where c.status = 'active' and c.kind = 'event'
     and p_date between c.starts_on and greatest(c.ends_on, coalesce(c.finale_on, c.ends_on))
     and exists (select 1 from public.competition_divisions d where d.competition_id = c.id and d.unit_id = p_unit)
   order by c.starts_on desc, c.created_at desc
   limit 1;
  if v_comp is null and coalesce(public.is_admin(), false) then
    select c.id into v_comp
      from public.competitions c
     where c.status = 'draft' and c.kind = 'event'
       and p_date between c.starts_on and greatest(c.ends_on, coalesce(c.finale_on, c.ends_on))
       and exists (select 1 from public.competition_divisions d where d.competition_id = c.id and d.unit_id = p_unit)
     order by c.starts_on desc, c.created_at desc
     limit 1;
  end if;
  if v_comp is null then
    select c.id into v_comp
      from public.competitions c
     where c.status = 'active' and c.kind = 'monthly'
     order by c.created_at desc
     limit 1;
  end if;
  if v_comp is null then
    return;
  end if;
  return query
    select c.id, c.name::text, c.status::text, r.rule_key::text, r.points, r.enabled
      from public.competitions c
      join public.competition_rules r on r.competition_id = c.id
     where c.id = v_comp
     order by r.rule_key;
end;
$$;

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
  -- 151: a draft competition is the admin's alone (no rows for anyone else)
  if not coalesce(public.is_admin(), false)
     and exists (select 1 from public.competitions c where c.id = p_competition and c.status = 'draft') then
    return;
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
  -- 151: a draft competition is the admin's alone (no rows for anyone else)
  if not coalesce(public.is_admin(), false)
     and exists (select 1 from public.competitions c where c.id = p_competition and c.status = 'draft') then
    return;
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

revoke all on function public.competition_rules_for_date(uuid, date) from public, anon;
grant execute on function public.competition_rules_for_date(uuid, date) to authenticated;
revoke all on function public.competition_standings(uuid, date, date)   from public, anon;
grant execute on function public.competition_standings(uuid, date, date)   to authenticated;
revoke all on function public.competition_unit_battle(uuid, date, date) from public, anon;
grant execute on function public.competition_unit_battle(uuid, date, date) to authenticated;

commit;
