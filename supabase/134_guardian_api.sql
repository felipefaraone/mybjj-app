-- ============================================================================
-- 134 — Guardian API (PHASE B1: database only)
-- ============================================================================
--
-- WHY
-- 133 made guardianship a first-class relation but gave the app no way to write
-- it: rows only appear through the legacy columns. This adds the server API the
-- frontend will call to add, request, approve, decline, revoke and list
-- guardians. No frontend change ships with this file.
--
-- PRODUCT RULES (final)
--  - Staff add a guardian directly. A guardian of a kid can REQUEST another
--    guardian; staff approve or decline. No parent ever grants access alone.
--  - An email that already belongs to an account activates at once; otherwise
--    the row is a pending invite that 133's claim_profile activates on first
--    sign-in.
--  - Adding a guardian sends NO email. The existing invite button
--    (send-magic-link) needs a whitelist row, so this API makes sure one
--    exists — without ever changing an existing row (whitelist_upsert would
--    overwrite the role, so it is never called from here).
--  - A guardian sees the other guardians of their kid as name + status only.
--    Staff see everything.
--
-- AUTHORISATION (each RPC checks at its top and raises a plain message)
--  staff of the kid  = is_admin()  OR  (is_staff() AND kid.unit_id = current_unit())
--                      (the same bar students_write uses for the kid's row)
--  guardian_add, guardian_link_member, guardian_request_decide, guardian_revoke:
--                      staff of the kid
--  guardian_request:   is_guardian_of(kid, 'manage'). Returns ONLY (id, status):
--                      no other column of any row reaches a parent caller.
--  kid_guardians:      staff of the kid (everything), or is_guardian_of(kid,'view')
--                      (name + status only); anyone else is refused
--
-- REVOKE MUST STICK
-- While the app still writes the legacy columns, the 133 sync trigger re-adds a
-- guardian whose legacy route is still set. So guardian_revoke first clears
-- every legacy route on the kid that resolves to that person (same matching as
-- 133: _guardianship_row_matches), then makes sure the row ends revoked. This
-- runs for EVERY origin, not only backfill/legacy_sync: a staff-added guardian
-- can also be the kid's parent_user_id (claim_profile sets it from a matching
-- parent_email), and leaving it would keep legacy access and recreate the row.
--
-- Rollback: 134_guardian_api_rollback.sql. Checks: 134_guardian_api_verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Preflight: the two notification CHECKs must hold exactly the values
--    migration 42 created. If production has drifted (an extra value this
--    file does not know about), abort rather than drop it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def  text;
  v_vals text[];
  r      record;
begin
  for r in select * from (values
    ('notifications_type_check',
     array['admin_message','feedback_received','photo_approved','photo_rejected','promotion']),
    ('notifications_related_entity_type_check',
     array['admin_message','feedback','photo_approval','promotion'])
  ) as t(conname, expected) loop
    select pg_get_constraintdef(c.oid) into v_def
      from pg_constraint c
     where c.conrelid = 'public.notifications'::regclass and c.conname = r.conname;
    if v_def is null then
      raise exception '134 preflight: constraint % not found on public.notifications', r.conname;
    end if;
    select array_agg(m[1] order by m[1]) into v_vals
      from regexp_matches(v_def, '''([^'']+)''', 'g') as m;
    -- A re-run finds the 134 values already present: accept old or old + new.
    if not (v_vals = r.expected
            or v_vals = (select array_agg(x order by x) from unnest(r.expected
                           || case r.conname when 'notifications_type_check' then array['guardian_request']
                                                                             else array['guardianship'] end) x)) then
      raise exception '134 preflight: % is % (expected %)', r.conname, v_vals, r.expected;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Notifications: old values + 'guardian_request' / 'guardianship'.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 2. Internal helpers. EXECUTE revoked from every client role below.
-- ---------------------------------------------------------------------------

-- Approved users who are staff of the unit (home unit OR staff_units), plus
-- every owner of the unit. Deduplicated.
create or replace function public._unit_staff_user_ids(p_unit uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct x.id), array[]::uuid[])
    from (
      select u.id
        from public.users u
        join public.staff st on st.user_id = u.id
       where u.status = 'approved'
         and st.active is not false
         and (st.unit_id = p_unit
              or exists (select 1 from public.staff_units su
                          where su.staff_id = st.id and su.unit_id = p_unit))
      union
      select uo.user_id from public.unit_owners uo where uo.unit_id = p_unit
    ) x
   where p_unit is not null
$$;

-- A 'parent' whitelist row for the address, only when NO row exists for it
-- (case-insensitive). Never touches an existing row.
create or replace function public._whitelist_ensure(p_email text, p_unit uuid, p_student uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if v_email is null then return; end if;
  if exists (select 1 from public.whitelist w where lower(w.email) = v_email) then return; end if;
  insert into public.whitelist (email, role, unit_id, student_id, invited_by)
  values (v_email, 'parent', p_unit, p_student,
          (select u.id from public.users u where u.id = auth.uid()))
  on conflict do nothing;
end;
$$;

-- Staff of the kid: the same bar students_write applies to the kid's row.
create or replace function public._guardian_can_manage(p_student uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin()
      or (public.is_staff()
          and exists (select 1 from public.students s
                       where s.id = p_student and s.unit_id = public.current_unit()))
$$;

-- Account emails (auth.users and public.users) of a set of accounts, plus the
-- given emails, normalised. Mirrors how 133's revoke pass builds its email set.
create or replace function public._guardian_emails(p_users uuid[], p_emails text[])
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct e), array[]::text[])
    from (
      select nullif(lower(btrim(x)), '') as e from unnest(coalesce(p_emails, array[]::text[])) x
      union
      select nullif(lower(btrim(au.email)), '') from auth.users au where au.id = any (coalesce(p_users, array[]::uuid[]))
      union
      select nullif(lower(btrim(pu.email)), '') from public.users pu where pu.id = any (coalesce(p_users, array[]::uuid[]))
    ) t
   where e is not null
$$;

-- The live row (requested/pending/active) on this kid that resolves to the
-- given person, by 133's _guardianship_row_matches. Null when none.
create or replace function public._guardian_find_live(
  p_student uuid, p_users uuid[], p_students uuid[], p_emails text[])
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select g.id
    from public.guardianships g
   where g.student_id = p_student
     and g.status in ('requested','pending','active')
     and public._guardianship_row_matches(
           g.id,
           coalesce(array_remove(p_users, null), array[]::uuid[]),
           coalesce(array_remove(p_students, null), array[]::uuid[]),
           public._guardian_emails(p_users, p_emails))
   order by (g.status = 'active') desc, g.created_at
   limit 1
$$;

-- One auth account for an address (case-insensitive), or null.
create or replace function public._guardian_account_for(p_email text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select au.id from auth.users au
   where lower(btrim(au.email)) = lower(btrim(p_email))
   order by au.created_at nulls last, au.id
   limit 1
$$;

-- No active primary on the kid yet (P1 of 133).
create or replace function public._guardian_no_active_primary(p_student uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (select 1 from public.guardianships o
                      where o.student_id = p_student and o.is_primary and o.status = 'active')
$$;

-- Input limits shared by guardian_add and guardian_request. Plain messages;
-- empty name / relationship stay allowed (they become null).
create or replace function public._guardian_check_lengths(p_email text, p_name text, p_relationship text)
returns void
language plpgsql
immutable
set search_path = public
as $$
begin
  if length(btrim(coalesce(p_email, ''))) > 254 then
    raise exception 'Email is too long (254 characters max).';
  end if;
  if length(btrim(coalesce(p_name, ''))) > 80 then
    raise exception 'Name is too long (80 characters max).';
  end if;
  if length(btrim(coalesce(p_relationship, ''))) > 40 then
    raise exception 'Relationship is too long (40 characters max).';
  end if;
end;
$$;

-- Approve a 'requested' row: active when the email has an account, else a
-- pending invite + whitelist row. approved_by/approved_at = the caller. The
-- ONE implementation behind guardian_request_decide(id, true) and
-- guardian_add on a requested row. Callers do the authorisation and the
-- status check; this re-checks the status so it can never reopen a closed row.
create or replace function public._guardian_approve(p_id uuid)
returns public.guardianships
language plpgsql
security definer
set search_path = public
as $$
declare
  g      public.guardianships;
  k      public.students;
  v_user uuid;
  v_id   uuid;
  r      public.guardianships;
begin
  select * into g from public.guardianships where id = p_id for update;
  if g.id is null or g.status <> 'requested' then
    raise exception 'Only an open request can be approved.';
  end if;
  select * into k from public.students where id = g.student_id;
  v_user := public._guardian_account_for(g.invite_email::text);
  if v_user is not null and v_user = k.user_id then
    raise exception 'A child can''t be their own guardian.';
  end if;
  -- The person may have become a guardian by another route since the request.
  select x.id into v_id
    from public.guardianships x
   where x.student_id = g.student_id and x.id <> g.id
     and x.status in ('requested','pending','active')
     and public._guardianship_row_matches(x.id,
           coalesce(array_remove(array[v_user], null), array[]::uuid[]), array[]::uuid[],
           public._guardian_emails(array[v_user], array[g.invite_email::text]))
   limit 1;
  if v_id is not null then
    raise exception 'This person is already a guardian of this child. Decline the request instead.';
  end if;

  if v_user is not null then
    update public.guardianships
       set guardian_user_id = v_user,
           status           = 'active',
           is_primary       = public._guardian_no_active_primary(g.student_id),
           approved_by      = auth.uid(),
           approved_at      = now()
     where id = g.id
    returning * into r;
  else
    update public.guardianships
       set status      = 'pending',
           is_primary  = public._guardian_no_active_primary(g.student_id),
           approved_by = auth.uid(),
           approved_at = now()
     where id = g.id
    returning * into r;
    perform public._whitelist_ensure(g.invite_email::text, k.unit_id, k.id);
  end if;
  return r;
end;
$$;

revoke all on function public._unit_staff_user_ids(uuid) from public, anon, authenticated;
revoke all on function public._whitelist_ensure(text, uuid, uuid) from public, anon, authenticated;
revoke all on function public._guardian_can_manage(uuid) from public, anon, authenticated;
revoke all on function public._guardian_emails(uuid[], text[]) from public, anon, authenticated;
revoke all on function public._guardian_find_live(uuid, uuid[], uuid[], text[]) from public, anon, authenticated;
revoke all on function public._guardian_account_for(text) from public, anon, authenticated;
revoke all on function public._guardian_no_active_primary(uuid) from public, anon, authenticated;
revoke all on function public._guardian_check_lengths(text, text, text) from public, anon, authenticated;
revoke all on function public._guardian_approve(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Client RPCs.
-- ---------------------------------------------------------------------------

-- a. Staff add a guardian by email.
create or replace function public.guardian_add(
  p_student uuid, p_email text, p_name text default null, p_relationship text default null)
returns public.guardianships
language plpgsql
security definer
set search_path = public
as $$
declare
  k       public.students;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_user  uuid;
  v_id    uuid;
  r       public.guardianships;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into k from public.students where id = p_student;
  if k.id is null then raise exception 'Student not found.'; end if;
  if not public._guardian_can_manage(k.id) then
    raise exception 'Only staff of this student''s unit can add a guardian.';
  end if;
  perform public._guardian_check_lengths(p_email, p_name, p_relationship);
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.';
  end if;
  if v_email = lower(btrim(coalesce(k.email, ''))) then
    raise exception 'That is the student''s own email, not a guardian''s.';
  end if;

  v_user := public._guardian_account_for(v_email);
  if v_user is not null and v_user = k.user_id then
    raise exception 'A student can''t be their own guardian.';
  end if;

  -- Same person already live on this kid. A parent's open request for them is
  -- approved (staff adding the person IS the approval); a pending or active
  -- row is returned unchanged.
  v_id := public._guardian_find_live(k.id, array[v_user], array[]::uuid[], array[v_email]);
  if v_id is not null then
    select * into r from public.guardianships where id = v_id;
    if r.status = 'requested' then
      return public._guardian_approve(r.id);
    end if;
    return r;
  end if;

  if v_user is not null then
    insert into public.guardianships
      (student_id, guardian_user_id, guardian_name, relationship, access, is_primary,
       status, origin, created_by, approved_by, approved_at)
    values
      (k.id, v_user, nullif(btrim(p_name), ''), nullif(btrim(p_relationship), ''), 'manage',
       public._guardian_no_active_primary(k.id),
       'active', 'staff', auth.uid(), auth.uid(), now())
    returning * into r;
  else
    insert into public.guardianships
      (student_id, invite_email, guardian_name, relationship, access, is_primary,
       status, origin, created_by)
    values
      (k.id, v_email, nullif(btrim(p_name), ''), nullif(btrim(p_relationship), ''), 'manage',
       public._guardian_no_active_primary(k.id),
       'pending', 'staff', auth.uid())
    returning * into r;
    perform public._whitelist_ensure(v_email, k.unit_id, k.id);
  end if;
  return r;
end;
$$;

-- b. Staff add an existing member (a students row) as guardian. Writes ONLY
--    guardianships, never the legacy columns.
create or replace function public.guardian_link_member(p_student uuid, p_guardian_student uuid)
returns public.guardianships
language plpgsql
security definer
set search_path = public
as $$
declare
  k       public.students;
  m       public.students;
  v_email text;
  v_id    uuid;
  r       public.guardianships;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into k from public.students where id = p_student;
  if k.id is null then raise exception 'Student not found.'; end if;
  if not public._guardian_can_manage(k.id) then
    raise exception 'Only staff of this student''s unit can add a guardian.';
  end if;
  if p_guardian_student is null or p_guardian_student = k.id then
    raise exception 'A student can''t be their own guardian.';
  end if;
  select * into m from public.students where id = p_guardian_student;
  if m.id is null then raise exception 'Member not found.'; end if;
  if m.active is false then raise exception 'That member is inactive.'; end if;
  if m.user_id is not null and m.user_id = k.user_id then
    raise exception 'A student can''t be their own guardian.';
  end if;
  v_email := nullif(lower(btrim(coalesce(m.email, ''))), '');

  v_id := public._guardian_find_live(k.id, array[m.user_id], array[m.id], array[v_email]);
  if v_id is not null then
    select * into r from public.guardianships where id = v_id;
    return r;
  end if;

  if m.user_id is not null then
    insert into public.guardianships
      (student_id, guardian_user_id, guardian_student_id, access, is_primary,
       status, origin, created_by, approved_by, approved_at)
    values
      (k.id, m.user_id, m.id, 'manage', public._guardian_no_active_primary(k.id),
       'active', 'staff', auth.uid(), auth.uid(), now())
    returning * into r;
  else
    insert into public.guardianships
      (student_id, guardian_student_id, invite_email, access, is_primary,
       status, origin, created_by)
    values
      (k.id, m.id, v_email, 'manage', public._guardian_no_active_primary(k.id),
       'pending', 'staff', auth.uid())
    returning * into r;
    if v_email is not null then
      perform public._whitelist_ensure(v_email, k.unit_id, k.id);
    end if;
  end if;
  return r;
end;
$$;

-- c. A guardian asks staff to add another guardian. Returns only the row's
--    id and status (the created row, or the person's existing live row on a
--    dedupe hit): a parent caller never receives any other column.
--    DROP first: an earlier draft returned public.guardianships, and CREATE OR
--    REPLACE cannot change a return type.
drop function if exists public.guardian_request(uuid, text, text, text);
create function public.guardian_request(
  p_student uuid, p_email text, p_name text default null, p_relationship text default null)
returns table (id uuid, status text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  k       public.students;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_user  uuid;
  v_id    uuid;
  v_who   text;
  v_staff uuid;
  r       public.guardianships;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into k from public.students where id = p_student;
  if k.id is null then raise exception 'Student not found.'; end if;
  if not public.is_guardian_of(k.id, 'manage') then
    raise exception 'Only a guardian of this child can request another guardian.';
  end if;
  perform public._guardian_check_lengths(p_email, p_name, p_relationship);
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.';
  end if;
  if v_email = lower(btrim(coalesce(k.email, ''))) then
    raise exception 'That is the child''s own email, not a guardian''s.';
  end if;
  v_user := public._guardian_account_for(v_email);
  if v_user is not null and v_user = k.user_id then
    raise exception 'A child can''t be their own guardian.';
  end if;

  v_id := public._guardian_find_live(k.id, array[v_user], array[]::uuid[], array[v_email]);
  if v_id is not null then
    return query select g.id, g.status from public.guardianships g where g.id = v_id;
    return;
  end if;

  if (select count(*) from public.guardianships g
       where g.student_id = k.id and g.status = 'requested') >= 3 then
    raise exception 'This child already has 3 open guardian requests. Wait for staff to review them.';
  end if;

  insert into public.guardianships
    (student_id, invite_email, guardian_name, relationship, access, is_primary,
     status, origin, created_by)
  values
    (k.id, v_email, nullif(btrim(p_name), ''), nullif(btrim(p_relationship), ''), 'manage', false,
     'requested', 'parent_request', auth.uid())
  returning * into r;

  v_who := coalesce(r.guardian_name, v_email);
  foreach v_staff in array public._unit_staff_user_ids(k.unit_id) loop
    perform public.create_notification(
      p_user_id             := v_staff,
      p_type                := 'guardian_request',
      p_title               := 'Guardian request',
      p_body                := 'Add ' || v_who || ' as a guardian of ' || coalesce(k.full_name, 'a child') || '?',
      p_related_entity_type := 'guardianship',
      p_related_entity_id   := r.id,
      p_metadata            := jsonb_build_object('student_id', k.id, 'guardianship_id', r.id),
      p_check_prefs         := true
    );
  end loop;
  return query select r.id, r.status;
end;
$$;

-- d. Staff approve or decline a request.
create or replace function public.guardian_request_decide(p_id uuid, p_approve boolean)
returns public.guardianships
language plpgsql
security definer
set search_path = public
as $$
declare
  g public.guardianships;
  r public.guardianships;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into g from public.guardianships where id = p_id for update;
  if g.id is null then raise exception 'Request not found.'; end if;
  if not public._guardian_can_manage(g.student_id) then
    raise exception 'Only staff of this student''s unit can decide a guardian request.';
  end if;
  if g.status <> 'requested' then
    raise exception 'This request was already decided (%).', g.status;
  end if;
  if p_approve is null then raise exception 'Approve or decline.'; end if;

  if not p_approve then
    update public.guardianships set status = 'declined' where id = g.id returning * into r;
    return r;
  end if;
  return public._guardian_approve(g.id);
end;
$$;

-- e. Staff revoke a guardian. Clears the legacy routes that resolve to the
--    same person first, so the 133 sync trigger cannot re-add them.
create or replace function public.guardian_revoke(p_id uuid)
returns public.guardianships
language plpgsql
security definer
set search_path = public
as $$
declare
  g        public.guardianships;
  k        public.students;
  gs       public.students;
  v_a      boolean := false;
  v_b      boolean := false;
  v_c      boolean := false;
  v_d1     boolean := false;
  v_d2     boolean := false;
  v_e      text;
  r        public.guardianships;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into g from public.guardianships where id = p_id for update;
  if g.id is null then raise exception 'Guardian not found.'; end if;
  if not public._guardian_can_manage(g.student_id) then
    raise exception 'Only staff of this student''s unit can remove a guardian.';
  end if;
  if g.status not in ('requested','pending','active') then
    raise exception 'This guardian is already %.', g.status;
  end if;

  select * into k from public.students where id = g.student_id for update;

  -- Which legacy routes resolve to this person (133's matching, every origin).
  if k.parent_user_id is not null then
    v_a := public._guardianship_row_matches(g.id, array[k.parent_user_id], array[]::uuid[],
                                            public._guardian_emails(array[k.parent_user_id], null));
  end if;
  if k.parent_student_id is not null then
    select * into gs from public.students where id = k.parent_student_id;
    if gs.id is not null then
      v_b := public._guardianship_row_matches(g.id,
               coalesce(array_remove(array[gs.user_id], null), array[]::uuid[]), array[gs.id],
               public._guardian_emails(array[gs.user_id], array[gs.email]));
    end if;
  end if;
  if k.parent2_student_id is not null then
    select * into gs from public.students where id = k.parent2_student_id;
    if gs.id is not null then
      v_c := public._guardianship_row_matches(g.id,
               coalesce(array_remove(array[gs.user_id], null), array[]::uuid[]), array[gs.id],
               public._guardian_emails(array[gs.user_id], array[gs.email]));
    end if;
  end if;
  v_e := nullif(lower(btrim(coalesce(k.parent_email, ''))), '');
  if v_e is not null then
    v_d1 := public._guardianship_row_matches(g.id, array[]::uuid[], array[]::uuid[], array[v_e]);
  end if;
  v_e := nullif(lower(btrim(coalesce(k.parent2_email, ''))), '');
  if v_e is not null then
    v_d2 := public._guardianship_row_matches(g.id, array[]::uuid[], array[]::uuid[], array[v_e]);
  end if;

  if v_a or v_b or v_c or v_d1 or v_d2 then
    update public.students set
      parent_user_id     = case when v_a  then null else parent_user_id     end,
      parent_student_id  = case when v_b  then null else parent_student_id  end,
      parent2_student_id = case when v_c  then null else parent2_student_id end,
      parent_email       = case when v_d1 then null else parent_email       end,
      parent_name        = case when v_d1 then null else parent_name        end,
      parent_phone       = case when v_d1 then null else parent_phone       end,
      parent2_email      = case when v_d2 then null else parent2_email      end,
      parent2_name       = case when v_d2 then null else parent2_name       end,
      parent2_phone      = case when v_d2 then null else parent2_phone      end
    where id = k.id;
  end if;

  -- The trigger above may already have revoked a legacy-origin row; either
  -- way it ends revoked, by this caller.
  update public.guardianships
     set status     = 'revoked',
         is_primary = false,
         revoked_at = case when status = 'revoked' then coalesce(revoked_at, now()) else now() end,
         revoked_by = auth.uid()
   where id = g.id
  returning * into r;

  -- The primary went: promote the oldest remaining active guardian.
  if g.is_primary and g.status = 'active' and public._guardian_no_active_primary(g.student_id) then
    update public.guardianships
       set is_primary = true
     where id = (select o.id from public.guardianships o
                  where o.student_id = g.student_id and o.status = 'active'
                  order by o.approved_at nulls last, o.created_at, o.id
                  limit 1);
  end if;
  return r;
end;
$$;

-- f. List a kid's guardians. Staff see everything; a guardian sees names and
--    statuses only (email, origin and dates come back null).
create or replace function public.kid_guardians(p_student uuid, p_include_closed boolean default false)
returns table (
  id           uuid,
  display_name text,
  status       text,
  is_primary   boolean,
  relationship text,
  email        text,
  origin       text,
  created_at   timestamptz,
  approved_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_staff boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  v_staff := public._guardian_can_manage(p_student);
  if not v_staff and not public.is_guardian_of(p_student, 'view') then
    raise exception 'Only staff or a guardian of this child can see its guardians.';
  end if;

  return query
  select g.id,
         coalesce(nullif(btrim(pu.full_name), ''),
                  nullif(btrim(gs.full_name), ''),
                  nullif(btrim(g.guardian_name), ''),
                  case when v_staff then g.invite_email::text end),
         g.status,
         g.is_primary,
         g.relationship,
         case when v_staff then coalesce(au.email, pu.email, gs.email, g.invite_email::text) end,
         case when v_staff then g.origin end,
         case when v_staff then g.created_at end,
         case when v_staff then g.approved_at end
    from public.guardianships g
    left join public.users pu    on pu.id = g.guardian_user_id
    left join auth.users au      on au.id = g.guardian_user_id
    left join public.students gs on gs.id = g.guardian_student_id
   where g.student_id = p_student
     and (g.status in ('requested','pending','active')
          or (v_staff and coalesce(p_include_closed, false)))
   order by g.is_primary desc,
            case g.status when 'active' then 0 when 'pending' then 1 when 'requested' then 2 else 3 end,
            g.created_at;
end;
$$;

revoke all on function public.guardian_add(uuid, text, text, text) from public, anon;
revoke all on function public.guardian_link_member(uuid, uuid) from public, anon;
revoke all on function public.guardian_request(uuid, text, text, text) from public, anon;
revoke all on function public.guardian_request_decide(uuid, boolean) from public, anon;
revoke all on function public.guardian_revoke(uuid) from public, anon;
revoke all on function public.kid_guardians(uuid, boolean) from public, anon;
grant execute on function public.guardian_add(uuid, text, text, text) to authenticated;
grant execute on function public.guardian_link_member(uuid, uuid) to authenticated;
grant execute on function public.guardian_request(uuid, text, text, text) to authenticated;
grant execute on function public.guardian_request_decide(uuid, boolean) to authenticated;
grant execute on function public.guardian_revoke(uuid) to authenticated;
grant execute on function public.kid_guardians(uuid, boolean) to authenticated;

commit;
