-- =============================================================================
-- myBJJ V1 — Phase 5 (Profile Photo upload + admin approval)
-- Run AFTER 10_phase4_5.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema bumps
-- ---------------------------------------------------------------------------

-- students.photo_url stores the Storage path of the LATEST APPROVED photo,
-- e.g. 'aar/1712345678.jpg'. NULL means no approved photo -> fall back to
-- initials avatar.
alter table public.students
  add column if not exists photo_url text;

-- photo_approvals needs the student subject and (optional) reject reason.
-- The existing user_id column stays as the SUBMITTER (auth.uid()) so a
-- staff member uploading on a student's behalf is recorded.
alter table public.photo_approvals
  add column if not exists student_id      uuid references public.students(id) on delete cascade,
  add column if not exists rejected_reason text;

create index if not exists idx_photo_approvals_student on public.photo_approvals(student_id);
create index if not exists idx_photo_approvals_pending on public.photo_approvals(status)
  where status = 'pending';

-- ---------------------------------------------------------------------------
-- 2. photo_approvals RLS (rewritten for Phase 5 permission model)
-- ---------------------------------------------------------------------------
-- INSERT  : any authenticated user (student uploading own / staff uploading
--           for a student in their unit).
-- SELECT  : owner sees all; instructor sees pending+history for their unit;
--           the submitter sees their own rows (so they can see pending status).
-- UPDATE  : owner sees all; black-belt instructor (Professor) can approve /
--           reject for students in their unit; Coach has no approval right.
-- DELETE  : admin/owner only.
-- ---------------------------------------------------------------------------
drop policy if exists photo_select on public.photo_approvals;
drop policy if exists photo_insert on public.photo_approvals;
drop policy if exists photo_update on public.photo_approvals;
drop policy if exists photo_delete on public.photo_approvals;

create policy photo_select on public.photo_approvals
  for select to authenticated
  using (
    public.is_admin()
    or user_id = auth.uid()
    or (
      public.is_staff()
      and exists (
        select 1 from public.students s
        where s.id = photo_approvals.student_id
          and s.unit_id = public.current_unit()
      )
    )
  );

create policy photo_insert on public.photo_approvals
  for insert to authenticated
  with check (user_id = auth.uid());

-- Approve / reject. Owner = full power. Otherwise must be a black-belt
-- instructor whose staff row is in the same unit as the student.
create policy photo_update on public.photo_approvals
  for update to authenticated
  using (
    public.current_role() = 'owner'
    or (
      public.is_staff()
      and exists (
        select 1 from public.staff st
        where st.user_id = auth.uid()
          and st.belt = 'black'
      )
      and exists (
        select 1 from public.students s
        where s.id = photo_approvals.student_id
          and s.unit_id = public.current_unit()
      )
    )
  )
  with check (true);

create policy photo_delete on public.photo_approvals
  for delete to authenticated
  using (public.is_admin());

-- ---------------------------------------------------------------------------
-- 3. Storage: avatars bucket + policies
-- ---------------------------------------------------------------------------
-- Public bucket so resolved URLs can be served directly without signing.
-- Writes are still gated by RLS on storage.objects.
insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do update set public = excluded.public;

drop policy if exists "avatars_authenticated_upload" on storage.objects;
drop policy if exists "avatars_authenticated_update" on storage.objects;
drop policy if exists "avatars_admin_delete"         on storage.objects;
drop policy if exists "avatars_public_read"          on storage.objects;

-- Anyone (even anon) can read — bucket is public for serving via URL.
create policy "avatars_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

-- Any authenticated user can upload to avatars/...
create policy "avatars_authenticated_upload"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars');

-- Authenticated users may overwrite (used by upsert flows; not used today).
create policy "avatars_authenticated_update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars')
  with check (bucket_id = 'avatars');

-- Deletes are restricted to admin/owner; reject flow uses an RPC.
create policy "avatars_admin_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and public.is_admin());

-- ---------------------------------------------------------------------------
-- 4. RPC: reject_photo
-- ---------------------------------------------------------------------------
-- Encapsulates the reject side effect: mark row rejected + remove the
-- storage object. SECURITY DEFINER so non-admin black-belt instructors can
-- delete the file (storage RLS otherwise blocks them).
-- ---------------------------------------------------------------------------
create or replace function public.reject_photo(
  p_id     uuid,
  p_reason text default null
) returns public.photo_approvals
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  v_row       public.photo_approvals;
  v_role      text := public.current_role();
  v_belt      text;
  v_unit_ok   boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select * into v_row from public.photo_approvals where id = p_id;
  if not found then
    raise exception 'photo_approval % not found', p_id;
  end if;

  -- owner is always allowed; otherwise must be a black-belt instructor
  -- whose unit matches the subject student.
  if v_role <> 'owner' then
    select belt into v_belt from public.staff where user_id = auth.uid() limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can reject photos';
    end if;
    select (s.unit_id = (select unit_id from public.staff where user_id = auth.uid() limit 1))
      into v_unit_ok
      from public.students s
      where s.id = v_row.student_id;
    if not v_unit_ok then
      raise exception 'not authorised: student is in another unit';
    end if;
  end if;

  update public.photo_approvals
     set status          = 'rejected',
         rejected_reason = p_reason,
         approved_by_id  = auth.uid(),
         approved_at     = now()
   where id = p_id
   returning * into v_row;

  -- Free the storage object. Empty try block: if the path is missing we
  -- don't want to fail the whole reject.
  if v_row.photo_url is not null and v_row.photo_url <> '' then
    begin
      delete from storage.objects
       where bucket_id = 'avatars' and name = v_row.photo_url;
    exception when others then null;
    end;
  end if;

  return v_row;
end;
$$;

grant execute on function public.reject_photo(uuid, text) to authenticated;
