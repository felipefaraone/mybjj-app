-- 150_competitions_seed_rollback.sql
--
-- Undo 150: delete the two seeded competitions. Their divisions, rules and any
-- results go with them (ON DELETE CASCADE). Awards are facts about students and
-- are NOT tied to a competition: they stay.

begin;

delete from public.competitions
 where (name = 'Christmas Cup 2026' and kind = 'event')
    or (name = 'Monthly race' and kind = 'monthly');

commit;
