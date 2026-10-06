-- 137_engagement_emails_verify.sql
--
-- Checks for 137_engagement_emails.sql. Every query stands alone.
-- V1-V3 are read-only. V4 writes throwaway rows inside a block it rolls back
-- before showing results: NOTHING PERSISTS. Run V4's three statements together.

-- ---------------------------------------------------------------------------
-- V1. Tables, RLS, constraints. Expected: 2 rows, rls = true; email_sends has
--     one SELECT policy, email_optouts none.
-- ---------------------------------------------------------------------------
select c.relname, c.relrowsecurity as rls,
       (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as policies,
       (select string_agg(conname, ', ' order by conname) from pg_constraint where conrelid = c.oid) as constraints
  from pg_class c
 where c.oid in ('public.email_sends'::regclass, 'public.email_optouts'::regclass)
 order by c.relname;

-- ---------------------------------------------------------------------------
-- V2. Client privileges. Expected: authenticated can only SELECT email_sends;
--     anon nothing; nobody can touch email_optouts.
-- ---------------------------------------------------------------------------
select t.tbl, r.role,
       has_table_privilege(r.role, t.tbl, 'select') as sel,
       has_table_privilege(r.role, t.tbl, 'insert') as ins,
       has_table_privilege(r.role, t.tbl, 'update') as upd,
       has_table_privilege(r.role, t.tbl, 'delete') as del
  from (values ('public.email_sends'), ('public.email_optouts')) t(tbl)
 cross join (values ('anon'), ('authenticated')) r(role)
 order by 1, 2;

-- ---------------------------------------------------------------------------
-- V3. Functions: SECURITY DEFINER, not callable by clients, callable by
--     service_role. Expected: 3 rows: definer t, anon f, authenticated f,
--     service_role t.
-- ---------------------------------------------------------------------------
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute') as service_role,
       pg_get_function_result(p.oid) as result
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('training_count', 'email_recipients_for_student', 'monthly_recap_candidates')
 order by 1;

-- ---------------------------------------------------------------------------
-- V4. Scenario proof on throwaway rows (rolled back). Needs two accounts in
--     auth.users joined to public.users. Expected: every pass = true.
--      1 training_count counts present rows in range (privates, two classes on
--        one day, each counted once per row; 'going' and out-of-range ignored)
--      2 adult: own students.email, lowercased/trimmed
--      3 adult without students.email: the linked account's email (varchar in
--        Supabase; proves the casts)
--      4 kid with two guardians: active (account email) + pending (invite),
--        never the kid's own email
--      5 kid with no guardian: no recipient
--      6 opt-out 'all' and opt-out of this kind remove the address; an opt-out
--        of ANOTHER kind does not
--      7 monthly_recap_candidates skips on-hold and inactive students
-- ---------------------------------------------------------------------------
create temp table if not exists _v137_results (n int, check_name text, pass boolean, detail text);
truncate _v137_results;
do $$
declare
  u1 uuid; u1mail text; u2 uuid; u2mail text;
  a uuid; a2 uuid; k uuid; k0 uuid; h uuid; x uuid;
  v text; c int; res jsonb := '[]'::jsonb;
begin
  select u.id, lower(btrim(au.email::text)) into u1, u1mail from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null order by u.id limit 1;
  select u.id, lower(btrim(au.email::text)) into u2, u2mail from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null and u.id <> u1 order by u.id limit 1;
  if u2 is null then raise exception 'V4 needs two accounts'; end if;

  begin
    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v137 Adult', 'Adult', 'adult', '  ZZ-V137-Adult@Example.INVALID ', true, 'ok') returning id into a;
    insert into public.attendance (student_id, status, class_date, class_type) values
      (a, 'present', '2031-01-05', 'beg'), (a, 'present', '2031-01-05', 'nogi'),   -- two on one day
      (a, 'present', '2031-01-20', 'private'),                                     -- a private lesson
      (a, 'going',   '2031-01-21', 'beg'),                                         -- not present
      (a, 'present', '2031-02-01', 'beg');                                         -- next month
    c := public.training_count(a, '2031-01-01', '2031-01-31');
    res := res || jsonb_build_object('n',1,'c','training_count = present rows in range','p', c = 3, 'd', c);

    select string_agg(r.email || '/' || r.is_guardian, ',') into v from public.email_recipients_for_student(a, 'monthly_recap') r;
    res := res || jsonb_build_object('n',2,'c','adult: own email, normalised','p', v = 'zz-v137-adult@example.invalid/false', 'd', v);

    insert into public.students (full_name, prog, user_id, active, standing)
      values ('zz v137 Linked', 'adult', u1, true, 'ok') returning id into a2;
    select string_agg(r.email, ',') into v from public.email_recipients_for_student(a2, 'monthly_recap') r;
    res := res || jsonb_build_object('n',3,'c','adult without email: linked account email','p', v = u1mail, 'd', v);

    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v137 Kid', 'Kid', 'kids', 'zz-v137-kid@example.invalid', true, 'ok') returning id into k;
    insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, approved_at)
      values (k, u2, 'active', 'staff', u2, now());
    insert into public.guardianships (student_id, invite_email, guardian_name, status, origin, created_by)
      values (k, 'zz-v137-pending@example.invalid', 'Pending Parent', 'pending', 'staff', u2);
    insert into public.guardianships (student_id, invite_email, status, origin, created_by)
      values (k, 'zz-v137-kid@example.invalid', 'pending', 'staff', u2);   -- the kid's own address as an invite
    select string_agg(r.email || '/' || r.is_guardian, ',' order by r.email) into v from public.email_recipients_for_student(k, 'monthly_recap') r;
    res := res || jsonb_build_object('n',4,'c','kid: active + pending guardians, never the kid''s own email','p',
             v = (select string_agg(e || '/true', ',' order by e) from unnest(array[u2mail, 'zz-v137-pending@example.invalid']) e), 'd', v);

    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 Kid Alone', 'kids', 'zz-v137-alone@example.invalid', true, 'ok') returning id into k0;
    select count(*) into c from public.email_recipients_for_student(k0, 'monthly_recap');
    res := res || jsonb_build_object('n',5,'c','kid with no guardian: nobody','p', c = 0, 'd', c);

    insert into public.email_optouts (email, kind) values ('ZZ-V137-pending@example.invalid', 'mia');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap') r where r.email = 'zz-v137-pending@example.invalid';
    v := c::text;
    insert into public.email_optouts (email, kind) values ('zz-v137-pending@example.invalid', 'monthly_recap');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap') r where r.email = 'zz-v137-pending@example.invalid';
    v := v || '/' || c;
    insert into public.email_optouts (email, kind) values (u2mail, 'all');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap');
    v := v || '/' || c;
    res := res || jsonb_build_object('n',6,'c','opt-outs: other kind keeps, this kind and all remove','p', v = '1/0/0', 'd', v);

    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 On Hold', 'adult', 'zz-v137-hold@example.invalid', true, 'on_hold') returning id into h;
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 Inactive', 'adult', 'zz-v137-inactive@example.invalid', false, 'ok') returning id into x;
    select string_agg(distinct m.student_name, ',' order by m.student_name) into v
      from public.monthly_recap_candidates('2031-01-01', '2031-01-31') m where m.student_name like 'zz v137%';
    res := res || jsonb_build_object('n',7,'c','candidates skip on-hold and inactive','p',
             v = 'zz v137 Adult,zz v137 Kid,zz v137 Kid Alone,zz v137 Linked', 'd', v);

    raise exception 'v137-rollback';
  exception when others then
    if sqlerrm <> 'v137-rollback' then raise; end if;
  end;
  insert into _v137_results
  select (j->>'n')::int, j->>'c', (j->>'p')::boolean, j->>'d' from jsonb_array_elements(res) j;
end $$;
select * from _v137_results order by n;
