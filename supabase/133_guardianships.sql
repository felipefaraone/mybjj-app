-- ============================================================================
-- 133 — Guardianship as a first-class relation (PHASE A: database only)
-- ============================================================================
--
-- WHY
-- A kid's access hangs on ONE column, students.parent_user_id, plus three side
-- mechanisms (parent_student_id, parent2_student_id, parent_email /
-- parent2_email) that can only ever fill that one column. A second parent can
-- therefore never see their child. Real case: Antonella is linked to her mum
-- Evelin; her dad sees nothing.
--
-- WHAT THIS DOES (fully backwards compatible, no frontend change)
--  1. public.guardianships: one row per person per kid, status lifecycle
--     requested -> pending -> active -> revoked/declined. Never deleted.
--  2. guardian_student_ids() / is_guardian_of(): the only two readers policies use.
--  3. Backfill from every legacy route (origin = 'backfill').
--  4. A legacy-sync trigger on students that mirrors the old columns in both
--     directions while the app still writes them (origin = 'legacy_sync'),
--     and a BEFORE DELETE trigger for guardian students that are deleted.
--  5. The 8 policies that grant through parent_user_id: original expression
--     kept verbatim, guardian path OR-ed on. Nothing is narrowed.
--  6. The functions that read the parent columns gain the guardian path.
--
-- PRODUCT RULES (head instructor)
--  - Staff can add a guardian directly. A parent can REQUEST another guardian;
--    staff approves. No parent ever grants access on their own. In Phase A only
--    staff and owners can write this table (RLS); 'requested' rows never
--    activate on claim.
--  - All guardians of a child have the same access ('manage' by default).
--  - Notifications go to every active guardian (feedback, promotion, kids
--    announcements). Emails from Edge Functions are Phase B.
--
-- UNLINKING STILL WORKS
-- "Clear guardian details" and "Unlink parent" clear a legacy column; the sync
-- trigger revokes the guardianship that column produced, unless another legacy
-- route on the kid still points at the same person. Rows a staff member, a
-- parent request or a claim created are never revoked by the trigger.
--
-- NOT IN THIS FILE
--  - admin_change_user_email is deliberately unchanged: an admin moving a
--    user to the address on an open invite is a legitimate way to claim it.
--  - Contact data (phones) stays in the legacy columns; guardianships has no
--    phone column. Where it lives long-term is a Phase B decision.
--
-- Rollback: 133_guardianships_rollback.sql. Checks: 133_guardianships_verify.sql.
-- ============================================================================


begin;

-- ---------------------------------------------------------------------------
-- 0. Preflight. The baseline export does not record PERMISSIVE/RESTRICTIVE, so
--    prove it here: abort unless each of the 8 policies exists with the
--    expected table, command and roles, and is PERMISSIVE.
-- ---------------------------------------------------------------------------
do $$
declare r record; v pg_policies;
begin
  for r in select * from (values
    ('public','attendance','attendance_delete','DELETE','authenticated'),
    ('public','attendance','attendance_insert','INSERT','authenticated'),
    ('public','attendance','attendance_select','SELECT','authenticated'),
    ('public','feedback','feedback_select','SELECT','authenticated'),
    ('public','health_waivers','hw_select','SELECT','authenticated'),
    ('storage','objects','waivers_read','SELECT','authenticated'),
    ('public','promotions','promotions_select','SELECT','authenticated'),
    ('public','students','students_select','SELECT','public')
  ) as t(sch, tbl, pol, cmd, roles) loop
    select * into v from pg_policies
     where schemaname = r.sch and tablename = r.tbl and policyname = r.pol;
    if v.policyname is null then
      raise exception '133 preflight: policy %.%.% not found', r.sch, r.tbl, r.pol;
    end if;
    if v.permissive <> 'PERMISSIVE' or v.cmd <> r.cmd or v.roles::text <> '{' || r.roles || '}' then
      raise exception '133 preflight: %.% is % % % (expected PERMISSIVE % {%})',
        r.tbl, r.pol, v.permissive, v.cmd, v.roles, r.cmd, r.roles;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
-- citext for invite_email, schema-qualified so nothing depends on the session
-- search_path. Abort, rather than guess, if citext is already installed
-- somewhere other than the extensions schema. Comparisons below still use
-- lower(invite_email::text) explicitly: the helper functions run with
-- search_path = public, where citext's own = operator is not visible and the
-- comparison would silently fall back to case-sensitive text =. Writers always
-- store lower(btrim(email)).
do $$
declare v_schema text;
begin
  select n.nspname into v_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'citext';
  if v_schema is not null and v_schema <> 'extensions' then
    raise exception '133 preflight: citext is installed in schema %, expected extensions', v_schema;
  end if;
end $$;
create extension if not exists citext with schema extensions;

create table if not exists public.guardianships (
  id                  uuid primary key default gen_random_uuid(),
  student_id          uuid not null references public.students(id) on delete cascade,
  guardian_user_id    uuid null references auth.users(id) on delete cascade,
  guardian_student_id uuid null references public.students(id) on delete set null,
  invite_email        extensions.citext null,
  guardian_name       text null,   -- display for pending invites only
  relationship        text null,   -- display only, never a permission
  access              text not null default 'manage' check (access in ('manage','view')),
  is_primary          boolean not null default false,
  status              text not null check (status in ('requested','pending','active','declined','revoked')),
  origin              text not null check (origin in ('backfill','legacy_sync','staff','parent_request','claim')),
  created_by          uuid null,
  created_at          timestamptz not null default now(),
  approved_by         uuid null,
  approved_at         timestamptz null,
  revoked_by          uuid null,
  revoked_at          timestamptz null,
  -- Scoped to live rows: a revoked row may lose its last identifier when the
  -- guardian student it pointed at is deleted (FK sets it null).
  constraint guardianships_identifies_someone
    check (status not in ('requested','pending','active')
           or guardian_user_id is not null or guardian_student_id is not null or invite_email is not null),
  constraint guardianships_created_by_required
    check (created_by is not null or origin in ('backfill','legacy_sync','claim')),
  constraint guardianships_active_has_user
    check (status <> 'active' or guardian_user_id is not null)
);

comment on table public.guardianships is
  'Who may act for a student. One row per person per kid. Revocation is an UPDATE to status=revoked, never a DELETE (migration 133).';

create unique index if not exists guardianships_live_user_uq
  on public.guardianships (student_id, guardian_user_id)
  where status in ('requested','pending','active') and guardian_user_id is not null;
create unique index if not exists guardianships_open_invite_uq
  on public.guardianships (student_id, invite_email)
  where status in ('requested','pending') and invite_email is not null;
create unique index if not exists guardianships_one_primary_uq
  on public.guardianships (student_id)
  where is_primary and status = 'active';
create index if not exists guardianships_user_status_idx
  on public.guardianships (guardian_user_id, status);
create index if not exists guardianships_student_status_idx
  on public.guardianships (student_id, status);

alter table public.guardianships enable row level security;

-- No recursion: these policies call only auth.uid(), is_staff()
-- (-> current_role(), which reads public.users) and is_admin()
-- (-> is_unit_owner_any(), which reads public.unit_owners). Nothing on this
-- path reads guardianships.
drop policy if exists guardianships_select on public.guardianships;
create policy guardianships_select on public.guardianships
  as permissive for select to authenticated
  using ((public.is_staff() or public.is_admin()) or guardian_user_id = (select auth.uid()));

drop policy if exists guardianships_insert on public.guardianships;
create policy guardianships_insert on public.guardianships
  as permissive for insert to authenticated
  with check (public.is_staff() or public.is_admin());

drop policy if exists guardianships_update on public.guardianships;
create policy guardianships_update on public.guardianships
  as permissive for update to authenticated
  using (public.is_staff() or public.is_admin())
  with check (public.is_staff() or public.is_admin());

-- Deliberately no DELETE policy: revoke = UPDATE status to 'revoked'.
-- Privileges made explicit instead of relying on the schema's default grants:
-- clients get SELECT/INSERT/UPDATE (RLS then decides), nobody gets DELETE.
revoke all on public.guardianships from public, anon, authenticated;
grant select, insert, update on public.guardianships to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The two sources every policy and function uses.
--    SECURITY DEFINER, owned by whoever runs this file (postgres in the SQL
--    Editor): postgres owns guardianships and RLS is not FORCEd, so these read
--    the table without its policies. That is what keeps students_select ->
--    guardian_student_ids() -> guardianships from recursing.
--    EXECUTE stays at the default (PUBLIC): students_select applies to role
--    public, so anon must be able to evaluate it (and gets an empty array).
-- ---------------------------------------------------------------------------
create or replace function public.guardian_student_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(g.student_id), array[]::uuid[])
    from public.guardianships g
   where g.guardian_user_id = auth.uid()
     and g.status = 'active'
$$;

create or replace function public.is_guardian_of(p_student uuid, p_need text default 'view')
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.guardianships g
     where g.student_id = p_student
       and g.guardian_user_id = auth.uid()
       and g.status = 'active'
       and case p_need
             when 'view'   then true
             when 'manage' then g.access = 'manage'
             else false            -- unknown need never grants
           end
  )
$$;

-- ---------------------------------------------------------------------------
-- 3. Internal helpers. ONE implementation of the rules, used by the backfill,
--    the legacy-sync trigger and the claim paths, so they cannot drift.
--    They write, so EXECUTE is revoked from every client role: they run only
--    from the trigger and from SECURITY DEFINER callers owned by postgres.
--
--    DEDUPE RULES (a person = one live row per kid):
--    L1  A live row (requested/pending/active) for this exact guardian_user_id
--        on this kid IS the person's row: activate/complete it, never insert.
--    L2  Else an unclaimed requested/pending row that names the same person
--        (invite_email = the user's auth.users or public.users email, or
--        guardian_student_id = a student row the user owns) is completed with
--        guardian_user_id and activated, instead of inserting a second row.
--    G1  A pending-by-student row is skipped if a live row already carries that
--        guardian_student_id.
--    G2  ...or if the guardian student's email already belongs to a live
--        guardian account on that kid; an unclaimed open invite with that
--        email gets guardian_student_id attached instead of a new row.
--        (Called only when the guardian student has no user_id: with one, the
--        route goes through L1/L2 instead.)
--    D1  An email invite is skipped when the address (case-insensitive,
--        trimmed) equals: the invite_email of any live row on that kid; the auth.users or
--        public.users email of any live guardian user on that kid; or the
--        students.email of any live guardian student on that kid.
--    D2  An email equal to the kid's own students.email is never an invite.
--    S1  Routes b/c never make a kid their own guardian (guardian student = the
--        kid, or owned by the kid's own account). Route a mirrors
--        parent_user_id as-is, so legacy parity holds even for odd rows.
--    P1  is_primary is set only when the kid has no primary yet, and is
--        recomputed on every activation, so the one-active-primary index can
--        never abort a claim or a trigger.
-- ---------------------------------------------------------------------------

-- Link an account to a kid (routes a, b, c with a known account).
create or replace function public._guardianship_link_user(
  p_student uuid, p_user uuid, p_guardian_student uuid, p_name text,
  p_want_primary boolean, p_origin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid;
  v_emails text[];
begin
  if p_student is null or p_user is null then return; end if;

  -- L1
  select g.id into v_id
    from public.guardianships g
   where g.student_id = p_student
     and g.guardian_user_id = p_user
     and g.status in ('requested','pending','active')
   order by (g.status = 'active') desc, g.created_at
   limit 1;

  -- L2
  if v_id is null then
    select array_agg(distinct e) into v_emails
      from (select lower(btrim(au.email)) as e from auth.users au where au.id = p_user
            union
            select lower(btrim(pu.email)) from public.users pu where pu.id = p_user) x
     where e is not null and e <> '';
    select g.id into v_id
      from public.guardianships g
     where g.student_id = p_student
       and g.guardian_user_id is null
       and g.status in ('requested','pending')
       and (lower(g.invite_email::text) = any (coalesce(v_emails, array[]::text[]))
            or g.guardian_student_id in (select s.id from public.students s where s.user_id = p_user))
     order by g.created_at
     limit 1;
  end if;

  if v_id is not null then
    update public.guardianships g
       set guardian_user_id    = p_user,
           guardian_student_id = coalesce(g.guardian_student_id, p_guardian_student),
           guardian_name       = coalesce(g.guardian_name, p_name),
           is_primary          = (g.is_primary or p_want_primary)
                                 and not exists (select 1 from public.guardianships o
                                                  where o.student_id = p_student and o.id <> g.id
                                                    and o.is_primary and o.status = 'active'),
           approved_at         = case when g.status = 'active' then g.approved_at else now() end,
           status              = 'active'
     where g.id = v_id;
    return;
  end if;

  insert into public.guardianships
    (student_id, guardian_user_id, guardian_student_id, guardian_name,
     access, is_primary, status, origin, approved_at)
  values
    (p_student, p_user, p_guardian_student, p_name,
     'manage',
     p_want_primary and not exists (select 1 from public.guardianships o
                                     where o.student_id = p_student and o.is_primary and o.status = 'active'),
     'active', p_origin, now())
  on conflict do nothing;
end;
$$;

-- A guardian student row with no account yet (routes b, c): pending.
create or replace function public._guardianship_add_pending_student(
  p_student uuid, p_guardian_student uuid, p_name text, p_want_primary boolean, p_origin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  if p_student is null or p_guardian_student is null then return; end if;

  select nullif(lower(btrim(s.email)), '') into v_email
    from public.students s where s.id = p_guardian_student;

  -- G1
  if exists (select 1 from public.guardianships g
              where g.student_id = p_student and g.guardian_student_id = p_guardian_student
                and g.status in ('requested','pending','active')) then
    return;
  end if;

  -- G2: an unclaimed open invite for the same address becomes this row.
  if v_email is not null then
    update public.guardianships g
       set guardian_student_id = p_guardian_student,
           guardian_name       = coalesce(g.guardian_name, p_name)
     where g.id = (select g2.id from public.guardianships g2
                    where g2.student_id = p_student and g2.guardian_student_id is null
                      and g2.status in ('requested','pending')
                      and lower(g2.invite_email::text) = v_email
                    order by g2.created_at limit 1);
    if found then return; end if;

    -- G2: a live guardian account with that address is the same person.
    if exists (select 1 from public.guardianships g
                left join auth.users au   on au.id = g.guardian_user_id
                left join public.users pu on pu.id = g.guardian_user_id
               where g.student_id = p_student and g.status in ('requested','pending','active')
                 and (lower(btrim(au.email)) = v_email or lower(btrim(pu.email)) = v_email)) then
      return;
    end if;
  end if;

  -- invite_email carries the guardian student's own address when it has one:
  -- the row stays identifiable if that student row is ever deleted (the FK sets
  -- guardian_student_id to null), and the owner of that address can claim it.
  insert into public.guardianships
    (student_id, guardian_student_id, invite_email, guardian_name,
     access, is_primary, status, origin)
  values
    (p_student, p_guardian_student, v_email, p_name,
     'manage',
     p_want_primary and not exists (select 1 from public.guardianships o
                                     where o.student_id = p_student and o.is_primary
                                       and o.status in ('requested','pending','active')),
     'pending', p_origin)
  on conflict do nothing;
end;
$$;

-- An email with no account behind it yet (route d): pending invite.
create or replace function public._guardianship_add_invite(
  p_student uuid, p_email text, p_name text, p_origin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if p_student is null or v_email is null then return; end if;

  -- D2
  if exists (select 1 from public.students k
              where k.id = p_student and lower(btrim(k.email)) = v_email) then
    return;
  end if;

  -- D1
  if exists (
    select 1
      from public.guardianships g
      left join auth.users au      on au.id = g.guardian_user_id
      left join public.users pu    on pu.id = g.guardian_user_id
      left join public.students gs on gs.id = g.guardian_student_id
     where g.student_id = p_student
       and g.status in ('requested','pending','active')
       and (lower(g.invite_email::text) = v_email
            or lower(btrim(au.email)) = v_email
            or lower(btrim(pu.email)) = v_email
            or lower(btrim(gs.email)) = v_email)
  ) then
    return;
  end if;

  insert into public.guardianships
    (student_id, invite_email, guardian_name, access, is_primary, status, origin)
  values
    (p_student, v_email, p_name, 'manage', false, 'pending', p_origin)
  on conflict do nothing;
end;
$$;

-- Apply every legacy route of one kid. Only ever adds or activates.
create or replace function public._guardianship_sync_student(p_student uuid, p_origin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  k       public.students;
  v_name  text;
  v_route record;
  v_gs    public.students;
begin
  select * into k from public.students where id = p_student;
  if k.id is null then return; end if;

  -- (a) parent_user_id -> active, primary. The name follows whichever legacy
  -- email the account answers to; parent_name when neither or the first does.
  if k.parent_user_id is not null then
    v_name := k.parent_name;
    if nullif(lower(btrim(k.parent2_email)), '') is not null
       and nullif(lower(btrim(k.parent_email)), '') is distinct from lower(btrim(k.parent2_email))
       and exists (select 1 from auth.users au where au.id = k.parent_user_id
                     and lower(btrim(au.email)) = lower(btrim(k.parent2_email))
                   union all
                   select 1 from public.users pu where pu.id = k.parent_user_id
                     and lower(btrim(pu.email)) = lower(btrim(k.parent2_email))) then
      v_name := k.parent2_name;
    end if;
    perform public._guardianship_link_user(k.id, k.parent_user_id, null, v_name, true, p_origin);
  end if;

  -- (b) parent_student_id, then (c) parent2_student_id.
  for v_route in
    select * from (values (k.parent_student_id,  k.parent_name,  true,  1),
                          (k.parent2_student_id, k.parent2_name, false, 2)) as r(gs_id, nm, want_primary, ord)
     order by ord
  loop
    continue when v_route.gs_id is null or v_route.gs_id = k.id;            -- S1
    select * into v_gs from public.students where id = v_route.gs_id;
    continue when v_gs.id is null;
    if v_gs.user_id is not null then
      continue when v_gs.user_id = k.user_id;                              -- S1
      perform public._guardianship_link_user(k.id, v_gs.user_id, v_gs.id, v_route.nm,
                                             v_route.want_primary, p_origin);
    else
      perform public._guardianship_add_pending_student(k.id, v_gs.id, v_route.nm,
                                                       v_route.want_primary, p_origin);
    end if;
  end loop;

  -- (d) the two legacy emails.
  perform public._guardianship_add_invite(k.id, k.parent_email,  k.parent_name,  p_origin);
  perform public._guardianship_add_invite(k.id, k.parent2_email, k.parent2_name, p_origin);
end;
$$;

-- Claim: activate PENDING rows addressed to this account. Requested rows wait
-- for staff. A row is skipped (left pending) when the account already has a
-- live row on that kid (L1 residue, listed by the verify file) or the kid is
-- the account's own student row.
create or replace function public._guardianship_claim(p_user uuid, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  r record;
begin
  if p_user is null then return; end if;
  for r in
    select g.id, g.student_id
      from public.guardianships g
     where g.status = 'pending'
       and (g.guardian_user_id is null or g.guardian_user_id = p_user)
       and ((v_email is not null and lower(g.invite_email::text) = v_email)
            or g.guardian_student_id in (select s.id from public.students s where s.user_id = p_user))
     order by g.created_at
  loop
    continue when exists (select 1 from public.guardianships o
                           where o.student_id = r.student_id and o.guardian_user_id = p_user
                             and o.id <> r.id and o.status in ('requested','pending','active'));
    continue when exists (select 1 from public.students s
                           where s.id = r.student_id and s.user_id = p_user);
    update public.guardianships g
       set guardian_user_id = p_user,
           status           = 'active',
           approved_at      = now(),
           is_primary       = g.is_primary
                              and not exists (select 1 from public.guardianships o
                                               where o.student_id = g.student_id and o.id <> g.id
                                                 and o.is_primary and o.status = 'active')
     where g.id = r.id;
  end loop;
end;
$$;

revoke all on function public._guardianship_link_user(uuid, uuid, uuid, text, boolean, text) from public, anon, authenticated;
revoke all on function public._guardianship_add_pending_student(uuid, uuid, text, boolean, text) from public, anon, authenticated;
revoke all on function public._guardianship_add_invite(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public._guardianship_sync_student(uuid, text) from public, anon, authenticated;
revoke all on function public._guardianship_claim(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Backfill. Same rules as the trigger (it IS the same function). Idempotent:
--    every insert is guarded by the dedupe rules plus ON CONFLICT DO NOTHING.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select s.id
      from public.students s
     where s.parent_user_id is not null
        or s.parent_student_id is not null
        or s.parent2_student_id is not null
        or nullif(btrim(s.parent_email), '') is not null
        or nullif(btrim(s.parent2_email), '') is not null
     order by s.id
  loop
    perform public._guardianship_sync_student(r.id, 'backfill');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Legacy sync trigger (transition only, until Phase B moves the writes).
--    Mirrors the legacy columns in BOTH directions, so "Unlink parent" and
--    "Clear guardian details" still remove access while the app writes them.
--
--    REVOCATION RULES (UPDATE only, before the add pass, one execution):
--    R1  Only routes whose value CHANGED are considered (parent_user_id,
--        parent_student_id, parent2_student_id, parent_email, parent2_email;
--        emails compared under the D1 normalisation, so a case/space edit is
--        not a change).
--    R2  Candidates: live rows on the kid that resolve to the person the OLD
--        value pointed at (same account, same guardian student, or same email
--        under D1, including the account's and the guardian student's emails).
--    R3  A candidate is revoked (status='revoked', revoked_at=now(),
--        revoked_by=auth.uid()) only if its origin is 'backfill' or
--        'legacy_sync' AND no route remaining on the NEW row resolves to the
--        same person. 'staff', 'parent_request' and 'claim' rows are never
--        revoked here.
--    R4  An OLD guardian student that no longer exists (it is being deleted
--        and the FK nulled the kid's column) is skipped here: deletion is the
--        BEFORE DELETE trigger's job, and rows that still carry an account or
--        an email stay live.
--    Then the add pass runs on NEW exactly like the backfill, so A -> B is
--    revoke-A-if-orphaned, then add-B.
-- ---------------------------------------------------------------------------

-- Does live/any row p_id resolve to someone in the given identity sets?
create or replace function public._guardianship_row_matches(
  p_id uuid, p_users uuid[], p_students uuid[], p_emails text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.guardianships g
      left join public.students gs on gs.id = g.guardian_student_id
      left join auth.users au      on au.id = g.guardian_user_id
      left join public.users pu    on pu.id = g.guardian_user_id
     where g.id = p_id
       and (   g.guardian_user_id = any (p_users)
            or gs.user_id = any (p_users)
            or g.guardian_student_id = any (p_students)
            or exists (select 1 from public.students s2
                        where s2.user_id = g.guardian_user_id and s2.id = any (p_students))
            or lower(g.invite_email::text) = any (p_emails)
            or lower(btrim(au.email)) = any (p_emails)
            or lower(btrim(pu.email)) = any (p_emails)
            or lower(btrim(gs.email)) = any (p_emails))
  )
$$;

create or replace function public._guardianship_revoke_orphans(p_old public.students, p_new public.students)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o_users uuid[] := array[]::uuid[]; o_students uuid[] := array[]::uuid[]; o_emails text[] := array[]::text[];
  n_users uuid[] := array[]::uuid[]; n_students uuid[] := array[]::uuid[]; n_emails text[] := array[]::text[];
  v_pair  record;
  v_gs    public.students;
  r       record;
begin
  -- R1/R2: the OLD side, changed routes only.
  if p_old.parent_user_id is not null
     and p_old.parent_user_id is distinct from p_new.parent_user_id then
    o_users := o_users || p_old.parent_user_id;
  end if;
  for v_pair in
    select * from (values (p_old.parent_student_id,  p_new.parent_student_id),
                          (p_old.parent2_student_id, p_new.parent2_student_id)) as t(o, n)
  loop
    continue when v_pair.o is null or v_pair.o is not distinct from v_pair.n;
    select * into v_gs from public.students where id = v_pair.o;
    continue when v_gs.id is null;                                          -- R4
    o_students := o_students || v_gs.id;
    if v_gs.user_id is not null then o_users := o_users || v_gs.user_id; end if;
    if nullif(lower(btrim(v_gs.email)), '') is not null then
      o_emails := o_emails || lower(btrim(v_gs.email));
    end if;
  end loop;
  for v_pair in
    select * from (values (nullif(lower(btrim(p_old.parent_email)),  ''), nullif(lower(btrim(p_new.parent_email)),  '')),
                          (nullif(lower(btrim(p_old.parent2_email)), ''), nullif(lower(btrim(p_new.parent2_email)), ''))) as t(o, n)
  loop
    continue when v_pair.o is null or v_pair.o is not distinct from v_pair.n;
    o_emails := o_emails || v_pair.o::text;
  end loop;

  if cardinality(o_users) = 0 and cardinality(o_students) = 0 and cardinality(o_emails) = 0 then
    return;
  end if;

  -- R3: everything the NEW row still points at.
  if p_new.parent_user_id is not null then n_users := n_users || p_new.parent_user_id; end if;
  for v_gs in
    select s.* from public.students s where s.id in (p_new.parent_student_id, p_new.parent2_student_id)
  loop
    n_students := n_students || v_gs.id;
    if v_gs.user_id is not null then n_users := n_users || v_gs.user_id; end if;
    if nullif(lower(btrim(v_gs.email)), '') is not null then
      n_emails := n_emails || lower(btrim(v_gs.email));
    end if;
  end loop;
  n_emails := n_emails
    || coalesce(array_remove(array[nullif(lower(btrim(p_new.parent_email)), ''),
                                   nullif(lower(btrim(p_new.parent2_email)), '')], null), array[]::text[])
    || coalesce((select array_agg(e) from (
                   select lower(btrim(au.email)) as e from auth.users au where au.id = any (n_users)
                   union
                   select lower(btrim(pu.email)) from public.users pu where pu.id = any (n_users)) x
                 where e is not null and e <> ''), array[]::text[]);

  for r in
    select g.id from public.guardianships g
     where g.student_id = p_new.id
       and g.status in ('requested','pending','active')
       and g.origin in ('backfill','legacy_sync')
  loop
    continue when not public._guardianship_row_matches(r.id, o_users, o_students, o_emails);
    continue when public._guardianship_row_matches(r.id, n_users, n_students, n_emails);
    update public.guardianships
       set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
     where id = r.id;
  end loop;
end;
$$;

revoke all on function public._guardianship_row_matches(uuid, uuid[], uuid[], text[]) from public, anon, authenticated;
revoke all on function public._guardianship_revoke_orphans(public.students, public.students) from public, anon, authenticated;

create or replace function public.trg_guardianship_legacy_sync_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'UPDATE' then
    perform public._guardianship_revoke_orphans(OLD, NEW);
  end if;
  perform public._guardianship_sync_student(NEW.id, 'legacy_sync');
  return null;
end;
$$;

drop trigger if exists trg_guardianship_legacy_sync on public.students;
create trigger trg_guardianship_legacy_sync
  after insert or update of parent_user_id, parent_email, parent2_email,
                            parent_student_id, parent2_student_id
  on public.students
  for each row
  execute function public.trg_guardianship_legacy_sync_fn();

-- ---------------------------------------------------------------------------
-- 6. Deleting a guardian student. The FK sets guardian_student_id to null; a
--    live row whose ONLY identifier was that student would then identify
--    nobody, so it is revoked first (any origin: the person it named is gone).
--    Rows that also carry guardian_user_id or invite_email stay live and just
--    lose guardian_student_id through the FK.
-- ---------------------------------------------------------------------------
create or replace function public.trg_guardianship_student_delete_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.guardianships
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
   where guardian_student_id = OLD.id
     and status in ('requested','pending','active')
     and guardian_user_id is null
     and invite_email is null;
  return OLD;
end;
$$;

drop trigger if exists trg_guardianship_student_delete on public.students;
create trigger trg_guardianship_student_delete
  before delete on public.students
  for each row
  execute function public.trg_guardianship_student_delete_fn();


-- ---------------------------------------------------------------------------
-- 7. The 8 baseline policies: original expression verbatim, guardian path OR-ed on.
-- ---------------------------------------------------------------------------

drop policy if exists attendance_delete on public.attendance;
create policy attendance_delete on public.attendance
  as permissive for delete to authenticated
  using (
    -- baseline, verbatim
    ((is_staff() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))))
    -- 133: guardianship
    OR public.is_guardian_of(attendance.student_id, 'manage')
  );

drop policy if exists attendance_insert on public.attendance;
create policy attendance_insert on public.attendance
  as permissive for insert to authenticated
  with check (
    -- baseline, verbatim
    ((is_staff() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))))
    -- 133: guardianship
    OR public.is_guardian_of(attendance.student_id, 'manage')
  );

drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance
  as permissive for select to authenticated
  using (
    -- baseline, verbatim
    ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR ((s.unit_id = current_unit()) AND (s.prog = 'adult'::text) AND (attendance.status = ANY (ARRAY['going'::text, 'present'::text])) AND is_adult_peer_here())))))))
    -- 133: guardianship
    OR (attendance.student_id = ANY ((SELECT public.guardian_student_ids())::uuid[]))
  );

drop policy if exists feedback_select on public.feedback;
create policy feedback_select on public.feedback
  as permissive for select to authenticated
  using (
    -- baseline, verbatim
    ((is_admin() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = feedback.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR (is_staff() AND (s.unit_id = current_unit()))))))))
    -- 133: guardianship
    OR (feedback.student_id = ANY ((SELECT public.guardian_student_ids())::uuid[]))
  );

drop policy if exists hw_select on public.health_waivers;
create policy hw_select on public.health_waivers
  as permissive for select to authenticated
  using (
    -- baseline, verbatim
    ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = health_waivers.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))))
    -- 133: guardianship
    OR (health_waivers.student_id = ANY ((SELECT public.guardian_student_ids())::uuid[]))
  );

drop policy if exists waivers_read on storage.objects;
create policy waivers_read on storage.objects
  as permissive for select to authenticated
  using (
    -- baseline, verbatim
    (((bucket_id = 'waivers'::text) AND (is_admin() OR (EXISTS ( SELECT 1
   FROM (health_waivers hw
     LEFT JOIN students s ON ((s.id = hw.student_id)))
  WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))))))
    -- 133: guardianship
    OR ((bucket_id = 'waivers'::text) AND (EXISTS ( SELECT 1
   FROM health_waivers hw
  WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND (hw.student_id = ANY ((SELECT public.guardian_student_ids())::uuid[]))))))
  );

drop policy if exists promotions_select on public.promotions;
create policy promotions_select on public.promotions
  as permissive for select to authenticated
  using (
    -- baseline, verbatim
    ((is_admin() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = promotions.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR (is_staff() AND (s.unit_id = current_unit()))))))))
    -- 133: guardianship
    OR (promotions.student_id = ANY ((SELECT public.guardian_student_ids())::uuid[]))
  );

drop policy if exists students_select on public.students;
create policy students_select on public.students
  as permissive for select to public
  using (
    -- baseline, verbatim
    ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (user_id = auth.uid()) OR (parent_user_id = auth.uid()) OR ((unit_id = current_unit()) AND (prog = 'adult'::text) AND is_adult_peer_here())))
    -- 133: guardianship
    OR (id = ANY ((SELECT public.guardian_student_ids())::uuid[]))
  );

-- ---------------------------------------------------------------------------
-- 8. The baseline functions: baseline body with the guardianship path added.
--    Signatures, return types, SECURITY DEFINER, volatility and search_path
--    are the baseline's own text. admin_change_user_email is NOT replaced.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_profile()
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := auth.email();
  v_name text;
  v_existing public.users;
  v_wl public.whitelist;
  v_stu uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_existing from public.users where id = v_uid;

  select * into v_wl
  from public.whitelist
  where lower(email) = lower(v_email)
  limit 1;

  if v_existing.id is not null then
    if v_wl.email is not null and v_existing.status = 'pending' then
      update public.users
         set status = 'approved',
             role = coalesce(v_wl.role, v_existing.role),
             unit_id = coalesce(v_wl.unit_id, v_existing.unit_id)
       where id = v_uid
       returning * into v_existing;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    -- Parent link — matches parent_email OR parent2_email.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    -- 133: activate pending guardianships addressed to this person (their email,
    -- or a guardian student row they now own). Requested rows are NOT touched:
    -- those still wait for staff.
    perform public._guardianship_claim(v_uid, v_email);

    if v_existing.unit_id is null then
      update public.users u
         set unit_id = sub.unit_id
        from (
          select coalesce(
            (select unit_id from public.students where user_id = v_uid limit 1),
            (select unit_id from public.staff where user_id = v_uid limit 1),
            (select unit_id from public.students where parent_user_id = v_uid limit 1),
            -- 133: same fallback through an active guardianship.
            (select s.unit_id from public.guardianships g join public.students s on s.id = g.student_id
              where g.guardian_user_id = v_uid and g.status = 'active' limit 1)
          ) as unit_id
        ) sub
       where u.id = v_uid
         and sub.unit_id is not null
       returning u.* into v_existing;
    end if;

    if v_existing.full_name is null or trim(v_existing.full_name) = '' then
      v_name := null;
      select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
        into v_name
        from public.students
       where lower(email) = lower(v_email)
       limit 1;
      if v_name is null or trim(v_name) = '' then
        select parent_name
          into v_name
          from public.students
         where lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email)
         limit 1;
      end if;
      -- 133: a pending invite can carry a display name of its own.
      if v_name is null or trim(v_name) = '' then
        select g.guardian_name
          into v_name
          from public.guardianships g
         where lower(g.invite_email::text) = lower(v_email)
           and g.guardian_name is not null
           and g.status in ('requested','pending','active')
         limit 1;
      end if;
      if v_name is not null and trim(v_name) <> '' then
        update public.users
           set full_name = v_name
         where id = v_uid
           and (full_name is null or trim(full_name) = '')
         returning * into v_existing;
      end if;
    end if;

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;

    return v_existing;
  end if;

  v_name := coalesce(
    (auth.jwt() -> 'user_metadata' ->> 'full_name'),
    (auth.jwt() -> 'user_metadata' ->> 'name'),
    null
  );

  if v_name is null or trim(v_name) = '' then
    select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
      into v_name
      from public.students
     where lower(email) = lower(v_email)
     limit 1;
  end if;
  if v_name is null or trim(v_name) = '' then
    select parent_name
      into v_name
      from public.students
     where lower(parent_email) = lower(v_email)
        or lower(parent2_email) = lower(v_email)
     limit 1;
  end if;
  -- 133: a pending invite can carry a display name of its own.
  if v_name is null or trim(v_name) = '' then
    select g.guardian_name
      into v_name
      from public.guardianships g
     where lower(g.invite_email::text) = lower(v_email)
       and g.guardian_name is not null
       and g.status in ('requested','pending','active')
     limit 1;
  end if;

  if v_wl.email is not null then
    insert into public.users (id, email, role, unit_id, status, full_name)
    values (v_uid, v_email, v_wl.role, v_wl.unit_id, 'approved', v_name)
    returning * into v_existing;

    if v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    -- 133: activate pending guardianships addressed to this person.
    perform public._guardianship_claim(v_uid, v_email);

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- Migration 59: re-link orphan kids on first login even when the
    -- parent has no whitelist row.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    -- 133: activate pending guardianships addressed to this person (mirrors the
    -- legacy links above, which also run for a pending user).
    perform public._guardianship_claim(v_uid, v_email);
  end if;

  return v_existing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.relink_orphan_kids_on_user_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Email path (unchanged).
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and (lower(parent_email)  = lower(new.email)
          or lower(parent2_email) = lower(new.email));

  -- Structured path (parent_student_id). Matches kids whose linked parent
  -- is the students row owned by this new user.
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and parent_student_id in (
       select id from public.students where user_id = new.id
     );

  -- 133: activate pending guardianships addressed to this person. At INSERT
  -- time their own student row is usually not linked yet; claim_profile runs
  -- the same activation again after linking it.
  perform public._guardianship_claim(new.id, new.email);

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_student_self(p_legacy_id text, p_payload jsonb)
 RETURNS students
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_id uuid;
  result    public.students;
BEGIN
  SELECT s.id INTO target_id
    FROM public.students s
   WHERE s.legacy_id = p_legacy_id
     AND (s.user_id = auth.uid() OR s.parent_user_id = auth.uid()
          OR public.is_guardian_of(s.id, 'manage') /* 133 */)
     AND s.active = true;

  IF target_id IS NULL THEN
    RAISE EXCEPTION 'Not authorized to edit this student profile' USING ERRCODE = '42501';
  END IF;

  UPDATE public.students
     SET
       full_name               = COALESCE(p_payload->>'full_name', full_name),
       first_name              = COALESCE(p_payload->>'first_name', first_name),
       last_name               = COALESCE(p_payload->>'last_name',  last_name),
       initials                = COALESCE(p_payload->>'initials', initials),
       date_of_birth           = COALESCE((p_payload->>'date_of_birth')::date, date_of_birth),
       bjj_start_date          = CASE WHEN p_payload ? 'bjj_start_date' THEN NULLIF(p_payload->>'bjj_start_date','')::date ELSE bjj_start_date END,
       training_started_at     = CASE WHEN p_payload ? 'training_started_at' THEN NULLIF(p_payload->>'training_started_at','')::date ELSE training_started_at END,
       phone                   = COALESCE(p_payload->>'phone', phone),
       gender                  = COALESCE(p_payload->>'gender', gender),
       weight_kg               = CASE WHEN p_payload ? 'weight_kg' THEN (p_payload->>'weight_kg')::integer ELSE weight_kg END,
       height_cm               = CASE WHEN p_payload ? 'height_cm' THEN (p_payload->>'height_cm')::integer ELSE height_cm END,
       emergency_contact_name  = COALESCE(p_payload->>'emergency_contact_name', emergency_contact_name),
       emergency_contact_phone = COALESCE(p_payload->>'emergency_contact_phone', emergency_contact_phone),
       has_mybjj_gi            = CASE WHEN p_payload ? 'has_mybjj_gi' THEN (p_payload->>'has_mybjj_gi')::boolean ELSE has_mybjj_gi END,
       social_handles          = CASE WHEN p_payload ? 'social_handles' THEN (p_payload->'social_handles') ELSE social_handles END
   WHERE id = target_id
   RETURNING * INTO result;

  RETURN result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.home_unit()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select unit_id from public.users    where id      = auth.uid()),
    (select unit_id from public.students where user_id = auth.uid() limit 1),
    (select unit_id from public.staff    where user_id = auth.uid() limit 1),
    (select unit_id from public.students where parent_user_id = auth.uid() limit 1),
    -- 133: same fallback through an active guardianship.
    (select s.unit_id from public.guardianships g join public.students s on s.id = g.student_id
      where g.guardian_user_id = auth.uid() and g.status = 'active' limit 1)
  )
$function$
;

CREATE OR REPLACE FUNCTION public.send_admin_message(p_audience text, p_target_user_id uuid DEFAULT NULL::uuid, p_title text DEFAULT NULL::text, p_body text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller_unit   uuid;
  v_is_owner_any  boolean;
  v_recipient_ids uuid[];
  v_recipient_id  uuid;
  v_count         int;
  v_cap           constant int := 200;
begin
  -- Gating
  if not (public.is_staff() or public.is_unit_owner_any()) then
    raise exception 'send_admin_message: caller is not staff or owner';
  end if;

  -- Validate inputs
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'send_admin_message: title is required';
  end if;

  if p_audience not in ('all_unit', 'all_adults', 'all_kids', 'specific_user') then
    raise exception 'send_admin_message: invalid audience %', p_audience;
  end if;

  v_caller_unit  := public.current_unit();
  v_is_owner_any := public.is_unit_owner_any();

  -- Resolve recipients
  if p_audience = 'specific_user' then
    if p_target_user_id is null then
      raise exception 'send_admin_message: specific_user audience requires p_target_user_id';
    end if;
    if v_is_owner_any then
      -- Owner: any approved user
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id and u.status = 'approved';
    else
      -- Instructor: only own unit
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id
        and u.unit_id = v_caller_unit
        and u.status = 'approved';
    end if;

  elsif p_audience = 'all_unit' then
    -- V1: own/caller unit only. TODO: support multi-unit owner with p_unit_id param.
    select array_agg(u.id) into v_recipient_ids
    from public.users u
    where u.unit_id = v_caller_unit
      and u.status = 'approved';

  elsif p_audience = 'all_adults' then
    -- Users linked to adult students (excludes parents & kids).
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.user_id = u.id
    where s.prog = 'adult'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);

  elsif p_audience = 'all_kids' then
    -- Kids have no accounts: notify their parent users.
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.parent_user_id = u.id
    where s.prog = 'kids'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);

    -- 133: plus every active guardian of an active kid, under the same approval
    -- and unit rules as the parent_user_id join above. Union = deduplicated.
    select array_agg(distinct x.id) into v_recipient_ids
    from (
      select unnest(coalesce(v_recipient_ids, array[]::uuid[])) as id
      union
      select u.id
      from public.users u
      join public.guardianships g on g.guardian_user_id = u.id and g.status = 'active'
      join public.students s on s.id = g.student_id
      where s.prog = 'kids'
        and s.active = true
        and u.status = 'approved'
        and (v_is_owner_any or u.unit_id = v_caller_unit)
    ) x;
  end if;

  v_recipient_ids := coalesce(v_recipient_ids, array[]::uuid[]);
  v_count := coalesce(array_length(v_recipient_ids, 1), 0);

  if v_count = 0 then
    return 0;
  end if;

  if v_count > v_cap then
    raise exception 'send_admin_message: audience exceeds % recipients (got %)', v_cap, v_count;
  end if;

  -- Fan-out
  foreach v_recipient_id in array v_recipient_ids loop
    perform public.create_notification(
      p_user_id             := v_recipient_id,
      p_type                := 'admin_message',
      p_title               := p_title,
      p_body                := p_body,
      p_related_entity_type := 'admin_message',
      p_related_entity_id   := null,            -- no entity, so no dedupe
      p_metadata            := jsonb_build_object(
                                 'sent_by', auth.uid(),
                                 'audience', p_audience
                               ),
      p_check_prefs         := true             -- announcements honor opt-out
    );
  end loop;

  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_feedback_added_fn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id         uuid;
  v_student_name    text;
  v_student_prog    text;
  v_instructor_name text;
  v_body            text;
  -- 133
  v_student_user_id uuid;
  v_guardian_body   text;
  v_guardian_id     uuid;
begin
  select
    coalesce(s.user_id, s.parent_user_id),
    s.full_name,
    s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s
  where s.id = NEW.student_id;

  -- Orphan student (no linked user/parent): skip silently
  if v_user_id is null
     and not exists (select 1 from public.guardianships g          -- 133
                      where g.student_id = NEW.student_id
                        and g.status = 'active'
                        and g.guardian_user_id is not null) then
    return NEW;
  end if;

  select coalesce(st.full_name, 'An instructor') into v_instructor_name
  from public.staff st
  where st.id = NEW.instructor_id;

  if v_student_prog = 'kids' then
    v_body := coalesce(v_instructor_name, 'An instructor')
              || ' left feedback for '
              || coalesce(v_student_name, 'your child') || '.';
  else
    v_body := coalesce(v_instructor_name, 'An instructor') || ' left you feedback.';
  end if;

  -- 133: guardians read what the parent read before. When the student has an
  -- account of their own, "you" means the student, so guardians get the
  -- third-person sentence instead.
  select s.user_id into v_student_user_id from public.students s where s.id = NEW.student_id;
  if v_student_user_id is null then
    v_guardian_body := v_body;
  else
    v_guardian_body := coalesce(v_instructor_name, 'An instructor')
                       || ' left feedback for '
                       || coalesce(v_student_name, 'your child') || '.';
  end if;

  if v_user_id is not null then  -- 133: may now be null when only guardians remain
  perform public.create_notification(
    p_user_id             := v_user_id,
    p_type                := 'feedback_received',
    p_title               := 'New feedback',
    p_body                := v_body,
    p_related_entity_type := 'feedback',
    p_related_entity_id   := NEW.id,
    p_metadata            := jsonb_build_object(
                               'student_id',    NEW.student_id,
                               'instructor_id', NEW.instructor_id
                             ),
    p_check_prefs         := true
  );
  end if;  -- 133

  -- 133: every active guardian, once each, skipping whoever was notified above.
  for v_guardian_id in
    select distinct g.guardian_user_id
      from public.guardianships g
     where g.student_id = NEW.student_id
       and g.status = 'active'
       and g.guardian_user_id is not null
       and g.guardian_user_id is distinct from v_user_id
  loop
    perform public.create_notification(
      p_user_id             := v_guardian_id,
      p_type                := 'feedback_received',
      p_title               := 'New feedback',
      p_body                := v_guardian_body,
      p_related_entity_type := 'feedback',
      p_related_entity_id   := NEW.id,
      p_metadata            := jsonb_build_object(
                                 'student_id',    NEW.student_id,
                                 'instructor_id', NEW.instructor_id
                               ),
      p_check_prefs         := true
    );
  end loop;

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_promotion_fn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_student_name text; v_student_prog text;
  v_promoter_name text; v_title text; v_body text;
  v_student_user_id uuid; v_guardian_body text; v_guardian_id uuid;  -- 133
begin
  if NEW.hidden is true then return NEW; end if;
  -- staff promotions are records, not events for the student inbox
  if NEW.student_id is null then return NEW; end if;
  select coalesce(s.user_id, s.parent_user_id), s.full_name, s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s where s.id = NEW.student_id;
  if v_user_id is null
     and not exists (select 1 from public.guardianships g  -- 133
                      where g.student_id = NEW.student_id and g.status = 'active'
                        and g.guardian_user_id is not null) then return NEW; end if;
  v_promoter_name := coalesce(NEW.promoted_by_name, 'Your instructor');
  if NEW.is_new_belt is true then
    v_title := 'New belt!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    else
      v_body := 'You were promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    end if;
  else
    v_title := 'New stripe!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' earned a new stripe from ' || v_promoter_name || '.';
    else
      v_body := 'You earned a new stripe from ' || v_promoter_name || '.';
    end if;
  end if;
  -- 133: guardians read what the parent read before; when the student has an
  -- account of their own, guardians get the third-person sentence.
  select s.user_id into v_student_user_id from public.students s where s.id = NEW.student_id;
  if v_student_user_id is null then
    v_guardian_body := v_body;
  elsif NEW.is_new_belt is true then
    v_guardian_body := coalesce(v_student_name, 'Your child') || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
  else
    v_guardian_body := coalesce(v_student_name, 'Your child') || ' earned a new stripe from ' || v_promoter_name || '.';
  end if;
  if v_user_id is not null then  -- 133
  perform public.create_notification(
    p_user_id := v_user_id, p_type := 'promotion', p_title := v_title, p_body := v_body,
    p_related_entity_type := 'promotion', p_related_entity_id := NEW.id,
    p_metadata := jsonb_build_object('student_id', NEW.student_id, 'from_belt', NEW.from_belt,
      'to_belt', NEW.to_belt, 'from_deg', NEW.from_deg, 'to_deg', NEW.to_deg, 'is_new_belt', NEW.is_new_belt),
    p_check_prefs := true);
  end if;  -- 133
  -- 133: every active guardian, once each, skipping whoever was notified above.
  for v_guardian_id in
    select distinct g.guardian_user_id from public.guardianships g
     where g.student_id = NEW.student_id and g.status = 'active'
       and g.guardian_user_id is not null
       and g.guardian_user_id is distinct from v_user_id
  loop
    perform public.create_notification(
      p_user_id := v_guardian_id, p_type := 'promotion', p_title := v_title, p_body := v_guardian_body,
      p_related_entity_type := 'promotion', p_related_entity_id := NEW.id,
      p_metadata := jsonb_build_object('student_id', NEW.student_id, 'from_belt', NEW.from_belt,
        'to_belt', NEW.to_belt, 'from_deg', NEW.from_deg, 'to_deg', NEW.to_deg, 'is_new_belt', NEW.is_new_belt),
      p_check_prefs := true);
  end loop;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.whitelist_remove(p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := lower(btrim(coalesce(p_email,'')));
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not (public.is_unit_owner_any() or public.is_staff()) then
    raise exception 'not authorised to remove';
  end if;

  if v_email = '' then
    return;
  end if;

  if exists (
    select 1 from public.students s
    where s.active is true
      and ( lower(coalesce(s.email,'')) = v_email
         or lower(coalesce(s.parent_email,'')) = v_email )
  ) then
    return;
  end if;

  -- 133: also keep the address while it belongs to anyone with a live
  -- guardianship: the invite address for requested/pending rows, the account
  -- address for active rows (auth.users, and public.users, which
  -- admin_change_user_email updates without touching auth.users). Same silent
  -- return as the check above. Only ever stricter.
  if exists (
    select 1 from public.guardianships g
    where g.status in ('requested','pending')
      and lower(btrim(coalesce(g.invite_email::text,''))) = v_email
  ) or exists (
    select 1 from public.guardianships g
    join auth.users au on au.id = g.guardian_user_id
    where g.status = 'active'
      and lower(btrim(coalesce(au.email,''))) = v_email
  ) or exists (
    select 1 from public.guardianships g
    join public.users pu on pu.id = g.guardian_user_id
    where g.status = 'active'
      and lower(btrim(coalesce(pu.email,''))) = v_email
  ) then
    return;
  end if;

  delete from public.whitelist where lower(email) = v_email;
end;
$function$
;

commit;
