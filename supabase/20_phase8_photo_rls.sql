-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — re-assert photo self-upload policies
-- Run AFTER 19_phase8_journey_seed.sql. Safe to re-run.
--
-- The existing policies in 02_rls.sql + 11_phase5.sql already let a
-- student insert their own photo_approvals row and upload to the avatars
-- bucket, but the bug report came from somewhere that wasn't easy to
-- pinpoint without the live error. This migration re-asserts every
-- policy that touches the self-upload path so we know the deployed RLS
-- matches the documented intent.
--
-- (The frontend was also setting student_id=null on student self-uploads,
-- which meant the approval flow couldn't route the photo back to the
-- right students row. That's fixed in index.html, not here.)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. public.photo_approvals — owner reads/inserts own row; admin sees all
-- ---------------------------------------------------------------------------
drop policy if exists photo_select on public.photo_approvals;
create policy photo_select on public.photo_approvals
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists photo_insert on public.photo_approvals;
create policy photo_insert on public.photo_approvals
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists photo_update on public.photo_approvals;
create policy photo_update on public.photo_approvals
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Allow the submitter to DELETE their own pending row. Today the frontend
-- "replace pending photo" flow uses delete-then-insert, but without an
-- explicit policy that only worked because the row had just been inserted
-- in the same session. This makes it deterministic.
drop policy if exists photo_delete on public.photo_approvals;
create policy photo_delete on public.photo_approvals
  for delete to authenticated
  using (
    (user_id = auth.uid() and status = 'pending')
    or public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- 2. storage.objects — avatars bucket. Public read, any authenticated
--    user can upload / overwrite within the bucket, admin can delete.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do update set public = excluded.public;

drop policy if exists "avatars_public_read"           on storage.objects;
drop policy if exists "avatars_authenticated_upload"  on storage.objects;
drop policy if exists "avatars_authenticated_update"  on storage.objects;
drop policy if exists "avatars_admin_delete"          on storage.objects;

create policy "avatars_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

create policy "avatars_authenticated_upload"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars');

create policy "avatars_authenticated_update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars')
  with check (bucket_id = 'avatars');

create policy "avatars_admin_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and public.is_admin());

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select policyname, cmd, qual
--   from pg_policies
--  where schemaname = 'public' and tablename = 'photo_approvals';
-- select policyname, cmd
--   from pg_policies
--  where schemaname = 'storage' and tablename = 'objects'
--    and policyname like 'avatars_%';
