-- 144_email_daily_limit_rollback.sql
--
-- Undo 144. ORDER: redeploy the previous mia-emails first (the 144 version calls
-- email_sent_today and, failing closed, sends no member email without it).
-- Drops no data: 144 added only this function.

begin;

drop function if exists public.email_sent_today(text, timestamptz);

commit;
