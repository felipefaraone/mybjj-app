-- =============================================================================
-- Migration 33: Drop nicknames
-- John flagged nicknames as a bullying risk for the kids cohort. We drop
-- the column from every table that carried it (users, students, staff)
-- and remove the set_my_nickname RPC. Safe to re-run.
-- =============================================================================

drop function if exists public.set_my_nickname(text, text);
drop function if exists public.set_my_nickname(text);
drop function if exists public.set_my_nickname();

alter table public.users    drop column if exists nickname;
alter table public.students drop column if exists nickname;
alter table public.staff    drop column if exists nickname;

do $$
declare v int;
begin
  select count(*) into v from information_schema.columns
   where table_schema='public' and column_name='nickname'
     and table_name in ('users','students','staff');
  if v > 0 then
    raise warning 'Some nickname columns still exist: %', v;
  else
    raise notice 'Migration 33: nickname columns dropped';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select table_name, column_name from information_schema.columns
--   where table_schema='public' and column_name='nickname';
-- -- Expect 0 rows.
-- select proname from pg_proc where proname='set_my_nickname';
-- -- Expect 0 rows.
