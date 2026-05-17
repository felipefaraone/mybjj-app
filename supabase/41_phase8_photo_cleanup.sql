-- =============================================================================
-- Migration 41: Photo sync (students/staff → users) + photo_update policy
--              clarification
-- Run AFTER 40_phase8_fix_legacy_owner_gates.sql. Idempotent.
--
-- Two problems addressed:
--
-- 1. PHOTO SYNC BUG
--    Approving a photo writes photo_url onto the target table
--    (public.students or public.staff) but never onto public.users.
--    Screens that hydrate avatars from public.users (peer roster, members)
--    fall back to initials even when the student/staff row carries a
--    valid Storage path. Confirmed: students.photo_url present but
--    users.photo_url NULL for the same auth user.
--
--    Fix:
--      a. AFTER UPDATE trigger on photo_approvals that fires on the
--         pending→approved transition. The trigger:
--           - mirrors photo_url onto students.photo_url or staff.photo_url
--             (idempotent — the frontend writes the same value)
--           - mirrors photo_url onto users.photo_url for the linked
--             user_id (this is the missing write)
--         Any future approver path (REST, admin script, another RPC)
--         inherits the sync automatically — no client-side
--         choreography required.
--      b. One-shot backfill: copy photo_url from public.students and
--         public.staff onto public.users for every linked user whose
--         users.photo_url is currently NULL. Idempotent because the
--         WHERE clause filters on `u.photo_url IS NULL`; re-running is
--         a no-op once the rows are populated.
--
-- 2. photo_update RLS POLICY CLARIFICATION (not a bug fix)
--    The brief flagged the photo_update policy in 11_phase5.sql:64-82
--    as still gated on `current_role() = 'owner'`. That policy was
--    superseded by 20_phase8_photo_rls.sql:30-34, which uses
--    `public.is_admin()`. After Batch 2A migration 32, is_admin() is
--    a thin wrapper over is_unit_owner_any(), so the active policy is
--    already correct (Mario passes via the canonical owner check).
--
--    We re-assert the policy here with the explicit canonical helper
--    (`is_unit_owner_any()`) instead of the backward-compat shim
--    (`is_admin()`). Behaviour-identical; the intent of the gate is
--    now self-evident from the policy text.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Trigger function: sync photo_url to users (and the subject table)
--    when a photo_approvals row transitions to status='approved'.
-- ---------------------------------------------------------------------------
create or replace function public.sync_photo_url_on_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  -- Fire only on the pending → approved edge. A re-update that leaves
  -- status='approved' (e.g. someone touching approved_at) must not
  -- re-trigger the cascade, otherwise an admin "undo" path that later
  -- nulls a photo_url could re-overwrite the source-of-truth tables.
  if NEW.status <> 'approved' then return NEW; end if;
  if OLD.status = 'approved' then return NEW; end if;
  if NEW.photo_url is null or NEW.photo_url = '' then return NEW; end if;

  -- Subject routing. photo_approvals rows have exactly one subject:
  -- student_id, staff_id, or neither (user-self upload — dev admin or
  -- any auth user without a staff/student linkage). The trigger mirrors
  -- onto the subject table AND resolves the linked auth user to mirror
  -- onto public.users.
  if NEW.student_id is not null then
    update public.students set photo_url = NEW.photo_url where id = NEW.student_id;
    select user_id into v_user_id from public.students where id = NEW.student_id;
  elsif NEW.staff_id is not null then
    update public.staff set photo_url = NEW.photo_url where id = NEW.staff_id;
    select user_id into v_user_id from public.staff where id = NEW.staff_id;
  else
    v_user_id := NEW.user_id;
  end if;

  if v_user_id is not null then
    update public.users set photo_url = NEW.photo_url where id = v_user_id;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_photo_approval_sync on public.photo_approvals;
create trigger trg_photo_approval_sync
after update on public.photo_approvals
for each row
execute function public.sync_photo_url_on_approval();

-- ---------------------------------------------------------------------------
-- 2. Backfill: copy photo_url from students/staff onto users for every
--    linked auth user where users.photo_url is currently NULL.
--
--    Idempotent: re-running is a no-op once users.photo_url is set,
--    because the WHERE clause filters on `u.photo_url is null`.
--
--    Two passes (students then staff) — the order is deterministic
--    even when a user is somehow linked to both (head professor edge
--    case): students wins because that pass runs first; the staff
--    pass then sees a non-null u.photo_url and skips.
-- ---------------------------------------------------------------------------
update public.users u
   set photo_url = s.photo_url
  from public.students s
  where s.user_id = u.id
    and s.photo_url is not null
    and u.photo_url is null;

update public.users u
   set photo_url = st.photo_url
  from public.staff st
  where st.user_id = u.id
    and st.photo_url is not null
    and u.photo_url is null;

-- ---------------------------------------------------------------------------
-- 3. photo_update RLS policy — re-assert with explicit is_unit_owner_any()
--    No functional change vs. the policy from 20_phase8_photo_rls.sql
--    (is_admin() is implemented as `select is_unit_owner_any()` post
--    migration 32). Re-asserting it removes one layer of indirection
--    and makes the intent of the gate obvious.
-- ---------------------------------------------------------------------------
drop policy if exists photo_update on public.photo_approvals;
create policy photo_update on public.photo_approvals
  for update to authenticated
  using (public.is_unit_owner_any())
  with check (public.is_unit_owner_any());

-- ---------------------------------------------------------------------------
-- 4. Verification
-- ---------------------------------------------------------------------------
do $$
declare
  v_trigger_count int;
  v_unsynced      int;
begin
  -- Trigger present
  select count(*) into v_trigger_count
    from pg_trigger
   where tgname = 'trg_photo_approval_sync'
     and tgrelid = 'public.photo_approvals'::regclass;
  raise notice 'Migration 41: trg_photo_approval_sync present = %', v_trigger_count;

  -- Any remaining backfill gap (linked auth user with subject photo
  -- but users.photo_url still NULL)
  select count(*) into v_unsynced
    from public.users u
    where u.photo_url is null
      and (
        exists (select 1 from public.students s
                 where s.user_id = u.id and s.photo_url is not null)
        or exists (select 1 from public.staff st
                   where st.user_id = u.id and st.photo_url is not null)
      );
  if v_unsynced > 0 then
    raise warning 'Migration 41: % users still missing photo_url after backfill', v_unsynced;
  else
    raise notice 'Migration 41: users.photo_url backfill complete';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Verification (run manually post-migration)
-- ---------------------------------------------------------------------------
-- 1. Backfill spot-check — every linked user with a subject photo should
--    have users.photo_url populated:
-- select u.id, u.email, u.photo_url, s.photo_url as student_photo
--   from public.users u
--   join public.students s on s.user_id = u.id
--  where s.photo_url is not null;
-- -- Expect: u.photo_url matches s.photo_url on every row.
--
-- select u.id, u.email, u.photo_url, st.photo_url as staff_photo
--   from public.users u
--   join public.staff st on st.user_id = u.id
--  where st.photo_url is not null;
-- -- Expect: u.photo_url matches st.photo_url on every row.
--
-- 2. Trigger smoke test — flip a pending photo_approvals row to
--    approved and confirm all three tables (subject + users) see the
--    new photo_url:
-- update public.photo_approvals set status='approved'
--  where id = '<pending uuid>';
-- select id, photo_url from public.students where id = (
--   select student_id from public.photo_approvals where id = '<uuid>');
-- select id, photo_url from public.users where id = (
--   select user_id from public.students where id = (
--     select student_id from public.photo_approvals where id = '<uuid>'));
--
-- 3. Confirm the active photo_update policy:
-- select polname, pg_get_expr(polqual, polrelid) as using_expr
--   from pg_policy
--  where polrelid = 'public.photo_approvals'::regclass
--    and polname = 'photo_update';
-- -- Expect: using_expr = is_unit_owner_any().
