-- 145_birthday_messages_rollback.sql
--
-- Undo 145. The app treats a failed load as an empty list (fallback message
-- "Have a great birthday."), so the table can go before or after the app.
-- Drops the seeded / edited messages with it.

begin;

drop table if exists public.birthday_messages;

commit;
