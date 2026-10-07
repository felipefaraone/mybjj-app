-- 140_mia_emails_rollback.sql
--
-- Undo 140_mia_emails.sql.
--
-- ORDER: unschedule the hourly job first (select cron.unschedule('mia-emails-hourly');)
-- and delete the mia-emails Edge Function (or stop calling it): it calls what
-- this drops.
--
-- DROPS DATA — export first if any of it matters:
--   select * from public.email_sends where kind = 'mia';
-- The rows go so a later re-run of 140 starts from a clean log (an R depends on
-- logged M1 rows). Opt-outs of kind 'mia' are KEPT: they are people asking not
-- to get these emails, and 137 already allowed the kind before 140 existed.

begin;

drop function if exists public.mia_email_candidates(timestamptz);
delete from public.email_sends where kind = 'mia';

commit;
