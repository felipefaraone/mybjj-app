-- 180_standings_all_units.sql
--
-- Leaderboard "All gyms" (Felipe, 28 Oct 2026): the adults of every gym in one
-- table, for fun (prizes and crowns stay per gym).
--
-- public.competition_standings_all_units(p_comp, p_from, p_to): the ADULT rows of
-- public.competition_standings(p_comp, p_from, p_to) (called, never re-derived),
-- every unit the caller can see, plus
--   unit_name       the unit's name;
--   combined_rank   rank() across all units, in _competition_ranked's order:
--                   points desc, classes_count desc, last_scored_on asc nulls last;
--   combined_place  the same rank among the prize-eligible only (staff skipped,
--                   ties share, the next person inherits), as prize_rank is built;
--   unit_short      the unit's short_code (the row's gym tag), else its name.
-- Everything else is competition_standings' own row, unchanged: its visibility
-- (approved users only; a draft is the admin's alone; an ended, unpublished event
-- shows nothing to members), its frozen rows (a published event, a closed month),
-- its per-unit rank / prize_rank and its Anonymous rule. Kids never combine: only
-- audience 'adult' is returned (a kid on an adult belt who ranks on the adults
-- board stays on it, as on the per-unit board).
--
-- Tie-break keys of an Anonymous row. competition_standings hides a hidden
-- member's classes_count and last_scored_on from everyone but staff, the member
-- and their guardian. For such a row the keys are taken from a visible row of the
-- same division with the same points: one with the same rank first (rank() ties
-- only on equal keys, so this is exact), else the nearest one below it, else the
-- nearest one above, and the gap in per-unit rank (k_sub) keeps it in its own
-- spot. So the within-unit order is always competition_standings' own, and the
-- combined order is exact unless a hidden member ties on points with another gym
-- and has no visible same-points neighbour in their own gym (none hidden today).
-- Staff and owners see every key: always exact for them.
--
-- public.units.short_code (Felipe, 28 Oct 2026): a gym's 2-4 character tag ("NB",
-- "CD"), nullable, unique where set. Set here for the two gyms by id, never by name:
--   Neutral Bay  c851cef5-d5b7-4d5b-b400-11f6ca760970  NB
--   Camperdown   3654625a-a157-4392-966a-7be69d4b0c6e  CD
-- A unit without one shows its name. units' own select policy covers the column.
--
-- SECURITY INVOKER (competition_standings applies its own rules to the caller),
-- execute for authenticated only. No new table, no change to competition_standings,
-- _competition_ranked or scoring.
-- Run with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/180_standings_all_units.sql

begin;

alter table public.units add column if not exists short_code text;
alter table public.units drop constraint if exists units_short_code_len;
alter table public.units add constraint units_short_code_len check (short_code is null or length(short_code) between 2 and 4);
create unique index if not exists units_short_code_key on public.units (short_code) where short_code is not null;

update public.units set short_code = 'NB' where id = 'c851cef5-d5b7-4d5b-b400-11f6ca760970';
update public.units set short_code = 'CD' where id = '3654625a-a157-4392-966a-7be69d4b0c6e';

drop function if exists public.competition_standings_all_units(uuid, date, date);   -- the return type changes
create or replace function public.competition_standings_all_units(p_comp uuid, p_from date default null, p_to date default null)
returns table (
  division_id uuid, unit_id uuid, unit_name text, audience text, student_id uuid, display_name text, photo_url text,
  points numeric, class_points numeric, gi_points numeric, nogi_points numeric, award_points numeric,
  referral_points numeric, classes_count integer, last_scored_on date, prize_eligible boolean,
  leaderboard_hidden boolean, rank integer, prize_rank integer, belt text, degree integer, minor boolean,
  checkin_points numeric, is_anonymous boolean, combined_rank integer, combined_place integer,
  unit_short text
)
language sql
stable
security invoker
set search_path = public
as $$
  with s as (
    select cs.*
      from public.competition_standings(p_comp, p_from, p_to) cs
     where cs.audience = 'adult'
  ),
  k as (
    select s.*,
           coalesce(s.prize_eligible, s.prize_rank is not null) as k_elig,   -- an Anonymous row keeps prize_rank
           case when v.rank is null then s.classes_count  else v.classes_count  end as k_classes,
           case when v.rank is null then s.last_scored_on else v.last_scored_on end as k_last,
           case when v.rank is not null then s.rank - v.rank
                when s.is_anonymous and s.classes_count is null then s.rank
                else 0 end as k_sub
      from s
      left join lateral (
        select t.rank, t.classes_count, t.last_scored_on
          from s t
         where t.division_id = s.division_id and t.points = s.points
           and not coalesce(t.is_anonymous, false)
         order by (t.rank < s.rank), abs(t.rank - s.rank)
         limit 1
      ) v on s.is_anonymous and s.classes_count is null
  ),
  r as (
    select k.*,
           (rank() over (order by k.points desc, k.k_classes desc, k.k_last asc nulls last, k.k_sub asc))::integer as c_rank,
           (case when k.k_elig then
              rank() over (partition by k.k_elig
                           order by k.points desc, k.k_classes desc, k.k_last asc nulls last, k.k_sub asc)
            end)::integer as c_place
      from k
  )
  select r.division_id, r.unit_id, u.name::text, r.audience, r.student_id, r.display_name, r.photo_url,
         r.points, r.class_points, r.gi_points, r.nogi_points, r.award_points,
         r.referral_points, r.classes_count, r.last_scored_on, r.prize_eligible,
         r.leaderboard_hidden, r.rank, r.prize_rank, r.belt, r.degree, r.minor,
         r.checkin_points, r.is_anonymous, r.c_rank, r.c_place,
         coalesce(u.short_code, u.name)::text
    from r
    left join public.units u on u.id = r.unit_id
   order by r.c_rank, u.name, r.display_name, r.student_id;
$$;

revoke all on function public.competition_standings_all_units(uuid, date, date) from public, anon;
grant execute on function public.competition_standings_all_units(uuid, date, date) to authenticated;

commit;
