-- 148_competitions_schema_rollback.sql
--
-- Undo 148. ORDER: run 150's rollback (seed) and 149's rollback (functions)
-- first. Drops data: every competition, award, result and the new student /
-- trial_bookings columns (leaderboard_hidden, prize_eligible, referrer fields).
-- No pre-existing table, column, policy or row is touched.

begin;

drop table if exists public.competition_results;
drop table if exists public.competition_awards;
drop table if exists public.competition_rules;
drop table if exists public.competition_divisions;
drop table if exists public.competitions;
drop table if exists public.competition_rule_catalog;

drop function if exists public.competition_awards_key_is_award();
drop function if exists public.competitions_touch_updated_at();

drop index if exists public.trial_bookings_referred_by_idx;
alter table public.trial_bookings drop column if exists referred_by_set_at;
alter table public.trial_bookings drop column if exists referred_by_set_by;
alter table public.trial_bookings drop column if exists referred_by_student_id;
alter table public.trial_bookings drop column if exists referrer_name;

alter table public.students drop column if exists prize_eligible;
alter table public.students drop column if exists leaderboard_hidden;

commit;
