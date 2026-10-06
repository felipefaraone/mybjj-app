-- 139_trial_emails_rollback.sql
--
-- Undo 139_trial_emails.sql.
--
-- ORDER: delete the trial-emails Edge Function (or stop calling it), redeploy
-- the previous trial-booking and email-unsubscribe, and push the previous
-- index.html first: all of them read or write what this drops.
--
-- DROPS DATA — export first if any of it matters:
--   select * from public.email_sends   where kind = 'trial';
--   select * from public.email_optouts where kind = 'trial';   -- people who asked to stop
--   select id, no_show_by, no_show_marked_at from public.trial_bookings where no_show_by is not null;

begin;

drop function if exists public.trial_email_candidates(timestamptz);
drop index if exists public.email_sends_trial_once;

delete from public.email_sends   where kind = 'trial';
delete from public.email_optouts where kind = 'trial';

alter table public.email_sends drop constraint if exists email_sends_kind_check;
alter table public.email_sends add constraint email_sends_kind_check
  check (kind in ('monthly_recap','mia'));
alter table public.email_optouts drop constraint if exists email_optouts_kind_check;
alter table public.email_optouts add constraint email_optouts_kind_check
  check (kind in ('all','monthly_recap','mia'));

alter table public.trial_bookings
  drop column if exists no_show_marked_at,
  drop column if exists no_show_by;

commit;
