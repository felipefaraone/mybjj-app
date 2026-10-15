-- 153_competitions_owner_tools_rollback.sql
--
-- Undo 153: drop the three owner functions and put the catalog's label and
-- description back exactly as 148 seeded them. Competitions, rules, divisions
-- and awards created through these functions stay (they are data).

begin;

drop function if exists public.competition_award_add_many(uuid[], text, date);
drop function if exists public.competition_set_status(uuid, text);
drop function if exists public.competition_save(jsonb);

update public.competition_rule_catalog set label = 'Classes attended',
       description = 'Every class marked present counts. Two classes on the same day both count. A private lesson counts at most private_cap.' where key = 'class_attended';
update public.competition_rule_catalog set label = 'Social post',
       description = 'Post about your training on social media and tag the academy. One per day.' where key = 'social_post';
update public.competition_rule_catalog set label = 'Class challenge',
       description = 'Win the challenge set in a class.' where key = 'class_challenge';
update public.competition_rule_catalog set label = 'Best attitude',
       description = 'Chosen by the instructor for the best attitude in a class.' where key = 'best_attitude';
update public.competition_rule_catalog set label = 'Friend tries a class',
       description = 'A friend you referred attends their first trial class.' where key = 'referral_trial';
update public.competition_rule_catalog set label = 'Friend joins',
       description = 'A friend you referred becomes a member.' where key = 'referral_conversion';

commit;
