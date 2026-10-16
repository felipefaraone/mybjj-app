-- 154_competition_notifications_rollback.sql
--
-- Undo 154: drop the two triggers and their functions, then put the
-- notifications CHECK constraints back to the lists 134 left (the same drop and
-- re-add 134's rollback uses).
--
-- It REFUSES first (raise, nothing changed) while any notification still uses a
-- 154 value, so it never fails halfway through the constraint swap. To clear
-- them, decide what should happen to those rows and run ONE of these yourself:
--   (dismissing them is not enough: dismissed rows still hold the values)
--   -- remove them:
--   delete from public.notifications
--    where type = 'competition_points'
--       or related_entity_type in ('competition_award', 'trial_referral');
--   -- or keep them as plain admin messages (same bell, no deep link):
--   update public.notifications
--      set type = 'admin_message', related_entity_type = 'admin_message', related_entity_id = null
--    where type = 'competition_points'
--       or related_entity_type in ('competition_award', 'trial_referral');
-- then run this file again.

begin;

do $$
declare n int;
begin
  select count(*) into n from public.notifications
   where type = 'competition_points'
      or related_entity_type in ('competition_award', 'trial_referral');
  if n > 0 then
    raise exception '154 rollback refused: % notification(s) still use competition_points / competition_award / trial_referral. Clear them first (see the top of this file), then run it again.', n;
  end if;
end $$;

drop trigger if exists trg_trial_referral_notify on public.trial_bookings;
drop trigger if exists trg_competition_awards_notify on public.competition_awards;
drop function if exists public.trial_referral_notify();
drop function if exists public.competition_awards_notify();
drop function if exists public._competition_pts(numeric);
drop function if exists public._competition_first_name(uuid);
drop function if exists public._competition_notify_recipients(uuid);
drop function if exists public._competition_notify_rule(uuid, date, text);

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'photo_approved', 'photo_rejected',
    'feedback_received', 'promotion',
    'admin_message',
    'guardian_request'                       -- 134
  ));

alter table public.notifications drop constraint if exists notifications_related_entity_type_check;
alter table public.notifications add constraint notifications_related_entity_type_check
  check (related_entity_type in (
    'photo_approval', 'feedback', 'promotion', 'admin_message',
    'guardianship'                           -- 134
  ));

commit;
