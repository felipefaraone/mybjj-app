-- 149_competitions_functions_rollback.sql
--
-- Undo 149: drop every function it created. ORDER: run 150's rollback first;
-- 148's rollback after this one. Drops no data. No pre-existing function is touched.

begin;

drop function if exists public.competition_finalize(uuid, date, date);
drop function if exists public.trial_set_referrer(uuid, uuid);
drop function if exists public.set_prize_eligible(uuid, boolean);
drop function if exists public.set_leaderboard_hidden(uuid, boolean);
drop function if exists public.competition_award_void(uuid);
drop function if exists public.competition_award_add(uuid, text, date, uuid, date, text);
drop function if exists public._competition_award_allowed(text);
drop function if exists public.competition_for_date(uuid, date);
drop function if exists public.competition_unit_battle(uuid, date, date);
drop function if exists public.competition_standings(uuid, date, date);
drop function if exists public._competition_ranked(uuid, date, date);
drop function if exists public._competition_scores(uuid, date, date);
drop function if exists public._competition_period(uuid, date, date);
drop function if exists public.trial_first_attended_on(uuid);
drop function if exists public._competition_audience(text);
drop function if exists public._competition_eligible(boolean, text, text);

commit;
