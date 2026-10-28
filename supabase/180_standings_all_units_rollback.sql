-- 180_standings_all_units_rollback.sql
--
-- Undoes 180: drops public.competition_standings_all_units and the units.short_code
-- column (its check and unique index go with it). 180 changed nothing else. Run on its own:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/180_standings_all_units_rollback.sql

begin;

drop function if exists public.competition_standings_all_units(uuid, date, date);
drop index if exists public.units_short_code_key;
alter table public.units drop column if exists short_code;

commit;
