-- 137_engagement_emails_rollback.sql
--
-- Undo 137_engagement_emails.sql.
--
-- ORDER: delete (or stop calling) the engagement-emails and email-unsubscribe
-- Edge Functions first; both read or write these objects.
--
-- DROPS DATA: the send log and every opt-out. Export the opt-outs first — they
-- are people who asked not to be emailed, and a later re-run must honour them:
--   select * from public.email_optouts;
--   select * from public.email_sends;

begin;

drop function if exists public.monthly_recap_candidates(date, date);
drop function if exists public.email_recipients_for_student(uuid, text);
drop function if exists public.training_count(uuid, date, date);
drop table if exists public.email_optouts;
drop table if exists public.email_sends;

commit;
