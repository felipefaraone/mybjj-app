-- 133_guardianships_verify.sql
--
-- Parity checks for 133_guardianships.sql. Every query stands alone: select
-- one, run it, read the comment above it for the expected result.
-- V1-V11 are read-only. V12 writes throwaway rows inside a block that it rolls
-- back before showing results, so nothing persists.

-- ---------------------------------------------------------------------------
-- V1. Counts by status and origin. (Informational.)
-- ---------------------------------------------------------------------------
select status, origin, count(*) as n
  from public.guardianships
 group by status, origin
 order by status, origin;

-- ---------------------------------------------------------------------------
-- V2. Every student with parent_user_id has an ACTIVE guardianship for that
--     same user. Expected: zero rows.
-- ---------------------------------------------------------------------------
select s.id as student_id, s.full_name, s.parent_user_id
  from public.students s
 where s.parent_user_id is not null
   and not exists (select 1 from public.guardianships g
                    where g.student_id = s.id
                      and g.guardian_user_id = s.parent_user_id
                      and g.status = 'active');

-- ---------------------------------------------------------------------------
-- V3. Legacy visibility is a subset of guardian visibility. For every user who
--     is parent_user_id somewhere, the kids they see through the legacy column
--     minus the kids guardian_student_ids() would return for them (expressed
--     over the table, not auth.uid()). Expected: zero rows.
-- ---------------------------------------------------------------------------
select s.parent_user_id as user_id, s.id as student_id
  from public.students s
 where s.parent_user_id is not null
except
select g.guardian_user_id, g.student_id
  from public.guardianships g
 where g.status = 'active';

-- ---------------------------------------------------------------------------
-- V4a. No duplicate live person per kid, by user. Expected: zero rows.
-- ---------------------------------------------------------------------------
select student_id, guardian_user_id, count(*) as n
  from public.guardianships
 where status in ('requested','pending','active') and guardian_user_id is not null
 group by student_id, guardian_user_id
having count(*) > 1;

-- ---------------------------------------------------------------------------
-- V4b. No duplicate live person per kid, by invite email (case-insensitive).
--      Expected: zero rows.
-- ---------------------------------------------------------------------------
select student_id, lower(invite_email::text) as invite_email, count(*) as n
  from public.guardianships
 where status in ('requested','pending','active') and invite_email is not null
 group by student_id, lower(invite_email::text)
having count(*) > 1;

-- ---------------------------------------------------------------------------
-- V4c. Cross-route duplicates: an ACTIVE account on a kid whose email
--      (auth.users or public.users) also sits on another live unclaimed row of
--      the same kid, or whose own student row is that row's guardian student.
--      Expected: zero rows. Any row here is claim residue (see report).
-- ---------------------------------------------------------------------------
select a.student_id, a.guardian_user_id, o.id as other_row, o.status, o.invite_email, o.guardian_student_id
  from public.guardianships a
  join public.guardianships o
    on o.student_id = a.student_id and o.id <> a.id
   and o.status in ('requested','pending') and o.guardian_user_id is null
  left join auth.users au   on au.id = a.guardian_user_id
  left join public.users pu on pu.id = a.guardian_user_id
 where a.status = 'active'
   and (lower(o.invite_email::text) in (lower(btrim(au.email)), lower(btrim(pu.email)))
        or o.guardian_student_id in (select s.id from public.students s where s.user_id = a.guardian_user_id));

-- ---------------------------------------------------------------------------
-- V5. Antonella: every guardianship row with names and emails, and her legacy
--     columns alongside, to see whether her dad was picked up.
--     Expected: her mum active + primary; her dad present (active if his
--     account was linked or has since logged in, else pending by email).
-- ---------------------------------------------------------------------------
select k.full_name                       as kid,
       g.status, g.origin, g.is_primary, g.access,
       coalesce(pu.full_name, gs.full_name, g.guardian_name) as guardian,
       coalesce(au.email, pu.email, gs.email, g.invite_email::text) as guardian_email,
       g.invite_email, g.guardian_student_id, g.approved_at,
       k.parent_name, k.parent_email, k.parent2_name, k.parent2_email,
       k.parent_student_id, k.parent2_student_id
  from public.students k
  left join public.guardianships g on g.student_id = k.id
  left join auth.users au      on au.id = g.guardian_user_id
  left join public.users pu    on pu.id = g.guardian_user_id
  left join public.students gs on gs.id = g.guardian_student_id
 where k.first_name ilike 'antonella%' or k.full_name ilike 'antonella%'
 order by k.full_name, g.is_primary desc, g.created_at;

-- ---------------------------------------------------------------------------
-- V6. Pending rows that nobody can ever claim: no account, no email, and no
--     guardian student that still exists. Expected: zero rows.
-- ---------------------------------------------------------------------------
select g.*
  from public.guardianships g
 where g.status in ('requested','pending')
   and g.guardian_user_id is null
   and g.invite_email is null
   and not exists (select 1 from public.students s where s.id = g.guardian_student_id);

-- ---------------------------------------------------------------------------
-- V7. Live rows that identify nobody. The identity check forbids them on live
--     rows, and deleting a guardian student revokes any row whose only
--     identifier was that student before the FK nulls it (V12 case 4 proves
--     the delete). Expected: zero rows.
-- ---------------------------------------------------------------------------
select g.*
  from public.guardianships g
 where g.status in ('requested','pending','active')
   and g.guardian_user_id is null
   and g.guardian_student_id is null
   and g.invite_email is null;

-- ---------------------------------------------------------------------------
-- V8. At most one active primary per kid, and kids with active guardians but
--     no primary. (Index enforces the first; the second is informational.)
-- ---------------------------------------------------------------------------
select student_id, count(*) filter (where is_primary) as primaries, count(*) as active_rows
  from public.guardianships
 where status = 'active'
 group by student_id
having count(*) filter (where is_primary) <> 1;

-- ---------------------------------------------------------------------------
-- V9. The 8 policies: still PERMISSIVE, same cmd and roles, guardian path
--     present. Expected: 8 rows, has_guardian_path = true on all.
-- ---------------------------------------------------------------------------
select schemaname, tablename, policyname, permissive, cmd, roles,
       coalesce(qual, '') || coalesce(with_check, '') ~ '(guardian_student_ids|is_guardian_of)' as has_guardian_path
  from pg_policies
 where (schemaname, policyname) in (('public','attendance_delete'), ('public','attendance_insert'),
         ('public','attendance_select'), ('public','feedback_select'), ('public','hw_select'),
         ('storage','waivers_read'), ('public','promotions_select'), ('public','students_select'))
 order by schemaname, tablename, policyname;

-- ---------------------------------------------------------------------------
-- V10. No-recursion preconditions: the SECURITY DEFINER readers are owned by a
--      role that bypasses RLS on guardianships (the table owner, or BYPASSRLS),
--      and RLS is not FORCEd. Expected: every row bypasses_rls = true and
--      force_rls = false.
-- ---------------------------------------------------------------------------
select p.proname, r.rolname as owner, p.prosecdef as security_definer,
       (r.rolbypassrls or r.rolsuper or r.oid = c.relowner) as bypasses_rls,
       c.relforcerowsecurity as force_rls
  from pg_proc p
  join pg_roles r on r.oid = p.proowner
  cross join (select relowner, relforcerowsecurity from pg_class where oid = 'public.guardianships'::regclass) c
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('guardian_student_ids','is_guardian_of','_guardianship_link_user',
                     '_guardianship_add_pending_student','_guardianship_add_invite',
                     '_guardianship_sync_student','_guardianship_claim','trg_guardianship_legacy_sync_fn',
                     '_guardianship_row_matches','_guardianship_revoke_orphans',
                     'trg_guardianship_student_delete_fn',
                     'home_unit','claim_profile','relink_orphan_kids_on_user_insert')
 order by p.proname;

-- ---------------------------------------------------------------------------
-- V11. Internal helpers are not callable by clients. Expected: all false.
-- ---------------------------------------------------------------------------
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute,
       has_function_privilege('anon', p.oid, 'execute')          as anon_can_execute
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname like '\_guardianship\_%';

-- ---------------------------------------------------------------------------
-- V12. Scenario proof of the revocation and delete rules, on throwaway rows.
--      Every write happens inside an inner block that is rolled back before the
--      results are stored: NOTHING PERSISTS (the temp table lives only for this
--      session). Run the three statements together.
--      Needs one existing account (public.users joined to auth.users) for
--      cases 1-4 and a second one for case 5; with only one, case 5 reports
--      pass = null (skipped).
--      Expected: every row pass = true.
--        1 unlink of parent_user_id revokes the row it produced
--        2 unlink of parent_user_id while parent_email still names the same
--          person does NOT revoke
--        3 a staff-origin row survives the unlink
--        4 deleting a guardian student with no email succeeds and revokes the
--          pending row that named only that student
--        5 changing parent_user_id from A to B revokes A and activates B
-- ---------------------------------------------------------------------------
create temp table if not exists _v133_results (n int, check_name text, pass boolean, detail text);
truncate _v133_results;
do $$
declare
  u1 uuid; u2 uuid; e1 text;
  k uuid; gst uuid; gid uuid; st text; st2 text;
  res jsonb := '[]'::jsonb;
begin
  select u.id, lower(btrim(au.email)) into u1, e1
    from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email), '') is not null
   order by u.id limit 1;
  select u.id into u2
    from public.users u join auth.users au on au.id = u.id
   where u.id <> u1 order by u.id limit 1;
  if u1 is null then raise exception 'V12 needs at least one account'; end if;

  begin
    -- 1
    insert into public.students (full_name, prog, parent_user_id)
      values ('zz v133 case 1', 'kids', u1) returning id into k;
    update public.students set parent_user_id = null where id = k;
    select status into st from public.guardianships where student_id = k and guardian_user_id = u1;
    res := res || jsonb_build_object('n',1,'c','unlink revokes','p', st = 'revoked','d', st);

    -- 2
    insert into public.students (full_name, prog, parent_user_id, parent_email)
      values ('zz v133 case 2', 'kids', u1, upper(e1)) returning id into k;
    update public.students set parent_user_id = null where id = k;
    select string_agg(status, ',') into st from public.guardianships where student_id = k;
    res := res || jsonb_build_object('n',2,'c','other route to same person keeps it','p', st = 'active','d', st);

    -- 3
    insert into public.students (full_name, prog) values ('zz v133 case 3', 'kids') returning id into k;
    insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, approved_at)
      values (k, u1, 'active', 'staff', u1, now());
    update public.students set parent_user_id = u1 where id = k;
    update public.students set parent_user_id = null where id = k;
    select string_agg(status || '/' || origin, ',') into st from public.guardianships where student_id = k;
    res := res || jsonb_build_object('n',3,'c','staff-origin row survives','p', st = 'active/staff','d', st);

    -- 4
    insert into public.students (full_name, prog) values ('zz v133 guardian', 'adult') returning id into gst;
    insert into public.students (full_name, prog, parent_student_id)
      values ('zz v133 case 4', 'kids', gst) returning id into k;
    select id into gid from public.guardianships where student_id = k and guardian_student_id = gst;
    delete from public.students where id = gst;
    select status into st from public.guardianships where id = gid;
    res := res || jsonb_build_object('n',4,'c','delete no-email guardian student','p',
                                     gid is not null and st = 'revoked','d', coalesce(st, 'no row'));

    -- 5
    if u2 is not null then
      insert into public.students (full_name, prog, parent_user_id)
        values ('zz v133 case 5', 'kids', u1) returning id into k;
      update public.students set parent_user_id = u2 where id = k;
      select status into st  from public.guardianships where student_id = k and guardian_user_id = u1;
      select status into st2 from public.guardianships where student_id = k and guardian_user_id = u2;
      res := res || jsonb_build_object('n',5,'c','A -> B revokes A, adds B','p',
                                       st = 'revoked' and st2 = 'active','d', st || ' / ' || st2);
    else
      res := res || jsonb_build_object('n',5,'c','A -> B revokes A, adds B','p', null,'d','skipped: one account');
    end if;

    raise exception 'v133-rollback';
  exception when others then
    if sqlerrm <> 'v133-rollback' then raise; end if;
  end;

  insert into _v133_results
  select (x->>'n')::int, x->>'c', (x->>'p')::boolean, x->>'d' from jsonb_array_elements(res) x;
end $$;
select * from _v133_results order by n;
