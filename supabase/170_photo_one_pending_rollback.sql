-- 170_photo_one_pending_rollback.sql
--
-- Undoes 170: drops its triggers and functions, puts every superseded row back
-- to pending (the state before 170, duplicates included: they reappear in the
-- photo queue) and restores 01's status check. Pending -> pending fires no
-- publish (41/167) and no notification (42).
-- The backup table public._bak_photo_approvals_pending_20261025 is kept; drop
-- it by hand once it is no longer needed.

begin;

drop trigger if exists trg_photo_one_pending on public.photo_approvals;
drop trigger if exists trg_photo_superseded_final on public.photo_approvals;

update public.photo_approvals set status = 'pending' where status = 'superseded';

alter table public.photo_approvals drop constraint if exists photo_approvals_status_check;
alter table public.photo_approvals
  add constraint photo_approvals_status_check check (status in ('pending', 'approved', 'rejected'));

drop function if exists public._photo_supersede_pending();
drop function if exists public._photo_superseded_is_final();
drop function if exists public._photo_supersede_duplicates();
drop function if exists public._photo_subject_key(uuid, uuid, uuid);

commit;
