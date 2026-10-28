-- 178_waiver_full_readers_rollback.sql
--
-- Undoes 178: drops its five functions and public.waiver_full_readers. Nothing
-- else was changed by 178 (no grant, policy or row of health_waivers).
-- Run 179's rollback FIRST if 179 is applied (179's waivers_read policy calls
-- can_read_full_waiver()); this file refuses to run while that policy exists.
-- Run on its own:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/178_waiver_full_readers_rollback.sql

begin;

do $$
begin
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname = 'waivers_read' and qual like '%can_read_full_waiver%') then
    raise exception '178 rollback: 179 is applied (waivers_read calls can_read_full_waiver); run 179''s rollback first';
  end if;
end $$;

drop function if exists public.waiver_trial_prefill(uuid);
drop function if exists public.waiver_trial_link_check(uuid);
drop function if exists public.waiver_alerts(uuid);
drop function if exists public.waiver_document(uuid, uuid);
drop function if exists public.can_read_full_waiver();
drop table if exists public.waiver_full_readers;

commit;
