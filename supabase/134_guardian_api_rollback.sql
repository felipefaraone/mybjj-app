-- 134_guardian_api_rollback.sql
--
-- Undo 134_guardian_api.sql: drops the six client RPCs and the internal helpers,
-- and puts the two notification CHECKs back to exactly migration 42's values.
--
-- DELETES DATA: notifications of type 'guardian_request' (and any with
-- related_entity_type 'guardianship') must go, or the restored CHECKs would
-- refuse the existing rows. Export them first if that matters:
--   select * from public.notifications
--    where type = 'guardian_request' or related_entity_type = 'guardianship';
--
-- KEPT: guardianship rows the API created (origin 'staff' / 'parent_request')
-- stay in public.guardianships. They are valid 133 rows; revoke them there if
-- needed. Legacy columns cleared by guardian_revoke are not restored. Whitelist
-- rows added by _whitelist_ensure stay.

begin;

drop function if exists public.kid_guardians(uuid, boolean);
drop function if exists public.guardian_revoke(uuid);
drop function if exists public.guardian_request_decide(uuid, boolean);
drop function if exists public.guardian_request(uuid, text, text, text);   -- returns table (id, status)
drop function if exists public.guardian_link_member(uuid, uuid);
drop function if exists public.guardian_add(uuid, text, text, text);
drop function if exists public._guardian_approve(uuid);
drop function if exists public._guardian_check_lengths(text, text, text);
drop function if exists public._guardian_no_active_primary(uuid);
drop function if exists public._guardian_account_for(text);
drop function if exists public._guardian_find_live(uuid, uuid[], uuid[], text[]);
drop function if exists public._guardian_emails(uuid[], text[]);
drop function if exists public._guardian_can_manage(uuid);
drop function if exists public._whitelist_ensure(text, uuid, uuid);
drop function if exists public._unit_staff_user_ids(uuid);

delete from public.notifications
 where type = 'guardian_request' or related_entity_type = 'guardianship';

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'photo_approved', 'photo_rejected',
    'feedback_received', 'promotion',
    'admin_message'
  ));

alter table public.notifications drop constraint if exists notifications_related_entity_type_check;
alter table public.notifications add constraint notifications_related_entity_type_check
  check (related_entity_type in (
    'photo_approval', 'feedback', 'promotion', 'admin_message'
  ));

commit;
