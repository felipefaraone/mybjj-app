-- 138_recipients_null_fix_verify.sql
--
-- Checks for 138_recipients_null_fix.sql. V1 is read-only. V2 writes throwaway
-- rows inside a block it rolls back before showing results: NOTHING PERSISTS.
-- Run V2's three statements together.

-- ---------------------------------------------------------------------------
-- V1. The function is 138's (null-safe predicate), still SECURITY DEFINER and
--     closed to clients. Expected: 1 row, null_safe t, definer t, anon f,
--     authenticated f, service_role t.
-- ---------------------------------------------------------------------------
select p.proname,
       pg_get_functiondef(p.oid) like '%is not distinct from s.own_email%' as null_safe,
       p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute') as service_role
  from pg_proc p
 where p.oid = 'public.email_recipients_for_student(uuid, text)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V2. Scenario proof (rolled back). Needs two accounts in auth.users joined to
--     public.users. Expected: every pass = true.
--   1 kid WITHOUT own email, guardians active + pending -> both (the 138 bug)
--   2 kid WITH own email equal to a guardian's invite -> that one excluded,
--     the other kept
--   3 adult without own email and without account -> nobody
--   4 student with prog NULL and an own email -> gets it (the second trap)
--   5 the case-1 kid through monthly_recap_candidates -> both recipients
--  11-17 the seven 137 V4 cases, unchanged
-- ---------------------------------------------------------------------------
create temp table if not exists _v138_results (n int, check_name text, pass boolean, detail text);
truncate _v138_results;
do $$
declare
  u1 uuid; u1mail text; u2 uuid; u2mail text;
  a uuid; a2 uuid; k uuid; k0 uuid; h uuid; x uuid; kn uuid; kw uuid; an uuid; pn uuid;
  v text; c int; res jsonb := '[]'::jsonb;
begin
  select u.id, lower(btrim(au.email::text)) into u1, u1mail from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null order by u.id limit 1;
  select u.id, lower(btrim(au.email::text)) into u2, u2mail from public.users u join auth.users au on au.id = u.id
   where nullif(btrim(au.email::text), '') is not null and u.id <> u1 order by u.id limit 1;
  if u2 is null then raise exception 'V2 needs two accounts'; end if;

  begin
    -- 1
    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v138 Kid NoEmail', 'Nia', 'kids', null, true, 'ok') returning id into kn;
    insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, approved_at)
      values (kn, u2, 'active', 'staff', u2, now());
    insert into public.guardianships (student_id, invite_email, guardian_name, status, origin, created_by)
      values (kn, 'zz-v138-pending@example.invalid', 'Pending Parent', 'pending', 'staff', u2);
    select string_agg(r.email || '/' || r.is_guardian, ',' order by r.email) into v from public.email_recipients_for_student(kn, 'monthly_recap') r;
    res := res || jsonb_build_object('n',1,'c','kid without own email: active + pending guardians','p',
             v = (select string_agg(e || '/true', ',' order by e) from unnest(array[u2mail, 'zz-v138-pending@example.invalid']) e), 'd', v);

    -- 2
    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v138 Kid WithEmail', 'Wes', 'kids', 'zz-v138-wes@example.invalid', true, 'ok') returning id into kw;
    insert into public.guardianships (student_id, invite_email, status, origin, created_by)
      values (kw, 'ZZ-v138-Wes@Example.invalid', 'pending', 'staff', u2);                   -- the kid's own address
    insert into public.guardianships (student_id, invite_email, guardian_name, status, origin, created_by)
      values (kw, 'zz-v138-other@example.invalid', 'Other Parent', 'pending', 'staff', u2);
    select string_agg(r.email, ',' order by r.email) into v from public.email_recipients_for_student(kw, 'monthly_recap') r;
    res := res || jsonb_build_object('n',2,'c','kid own email = a guardian invite: that one excluded, other kept','p',
             v = 'zz-v138-other@example.invalid', 'd', v);

    -- 3
    insert into public.students (full_name, prog, email, user_id, active, standing)
      values ('zz v138 Adult Nobody', 'adult', null, null, true, 'ok') returning id into an;
    select count(*) into c from public.email_recipients_for_student(an, 'monthly_recap');
    res := res || jsonb_build_object('n',3,'c','adult without own email and account: nobody','p', c = 0, 'd', c);

    -- 4
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v138 Null Prog', null, 'zz-v138-nullprog@example.invalid', true, 'ok') returning id into pn;
    select string_agg(r.email || '/' || r.is_guardian, ',') into v from public.email_recipients_for_student(pn, 'monthly_recap') r;
    res := res || jsonb_build_object('n',4,'c','prog NULL with own email: gets it','p', v = 'zz-v138-nullprog@example.invalid/false', 'd', v);

    -- 5
    select string_agg(m.email, ',' order by m.email) into v
      from public.monthly_recap_candidates('2031-01-01', '2031-01-31') m where m.student_id = kn;
    res := res || jsonb_build_object('n',5,'c','candidates: kid without own email has both guardians','p',
             v = (select string_agg(e, ',' order by e) from unnest(array[u2mail, 'zz-v138-pending@example.invalid']) e), 'd', v);

    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v137 Adult', 'Adult', 'adult', '  ZZ-V137-Adult@Example.INVALID ', true, 'ok') returning id into a;
    insert into public.attendance (student_id, status, class_date, class_type) values
      (a, 'present', '2031-01-05', 'beg'), (a, 'present', '2031-01-05', 'nogi'),   -- two on one day
      (a, 'present', '2031-01-20', 'private'),                                     -- a private lesson
      (a, 'going',   '2031-01-21', 'beg'),                                         -- not present
      (a, 'present', '2031-02-01', 'beg');                                         -- next month
    c := public.training_count(a, '2031-01-01', '2031-01-31');
    res := res || jsonb_build_object('n',11,'c','137: training_count = present rows in range','p', c = 3, 'd', c);

    select string_agg(r.email || '/' || r.is_guardian, ',') into v from public.email_recipients_for_student(a, 'monthly_recap') r;
    res := res || jsonb_build_object('n',12,'c','137: adult: own email, normalised','p', v = 'zz-v137-adult@example.invalid/false', 'd', v);

    insert into public.students (full_name, prog, user_id, active, standing)
      values ('zz v137 Linked', 'adult', u1, true, 'ok') returning id into a2;
    select string_agg(r.email, ',') into v from public.email_recipients_for_student(a2, 'monthly_recap') r;
    res := res || jsonb_build_object('n',13,'c','137: adult without email: linked account email','p', v = u1mail, 'd', v);

    insert into public.students (full_name, first_name, prog, email, active, standing)
      values ('zz v137 Kid', 'Kid', 'kids', 'zz-v137-kid@example.invalid', true, 'ok') returning id into k;
    insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, approved_at)
      values (k, u2, 'active', 'staff', u2, now());
    insert into public.guardianships (student_id, invite_email, guardian_name, status, origin, created_by)
      values (k, 'zz-v137-pending@example.invalid', 'Pending Parent', 'pending', 'staff', u2);
    insert into public.guardianships (student_id, invite_email, status, origin, created_by)
      values (k, 'zz-v137-kid@example.invalid', 'pending', 'staff', u2);   -- the kid's own address as an invite
    select string_agg(r.email || '/' || r.is_guardian, ',' order by r.email) into v from public.email_recipients_for_student(k, 'monthly_recap') r;
    res := res || jsonb_build_object('n',14,'c','137: kid: active + pending guardians, never the kid''s own email','p',
             v = (select string_agg(e || '/true', ',' order by e) from unnest(array[u2mail, 'zz-v137-pending@example.invalid']) e), 'd', v);

    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 Kid Alone', 'kids', 'zz-v137-alone@example.invalid', true, 'ok') returning id into k0;
    select count(*) into c from public.email_recipients_for_student(k0, 'monthly_recap');
    res := res || jsonb_build_object('n',15,'c','137: kid with no guardian: nobody','p', c = 0, 'd', c);

    insert into public.email_optouts (email, kind) values ('ZZ-V137-pending@example.invalid', 'mia');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap') r where r.email = 'zz-v137-pending@example.invalid';
    v := c::text;
    insert into public.email_optouts (email, kind) values ('zz-v137-pending@example.invalid', 'monthly_recap');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap') r where r.email = 'zz-v137-pending@example.invalid';
    v := v || '/' || c;
    insert into public.email_optouts (email, kind) values (u2mail, 'all');
    select count(*) into c from public.email_recipients_for_student(k, 'monthly_recap');
    v := v || '/' || c;
    res := res || jsonb_build_object('n',16,'c','137: opt-outs: other kind keeps, this kind and all remove','p', v = '1/0/0', 'd', v);

    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 On Hold', 'adult', 'zz-v137-hold@example.invalid', true, 'on_hold') returning id into h;
    insert into public.students (full_name, prog, email, active, standing)
      values ('zz v137 Inactive', 'adult', 'zz-v137-inactive@example.invalid', false, 'ok') returning id into x;
    select string_agg(distinct m.student_name, ',' order by m.student_name) into v
      from public.monthly_recap_candidates('2031-01-01', '2031-01-31') m where m.student_name like 'zz v137%';
    res := res || jsonb_build_object('n',17,'c','137: candidates skip on-hold and inactive','p',
             v = 'zz v137 Adult,zz v137 Kid,zz v137 Kid Alone,zz v137 Linked', 'd', v);

    raise exception 'v138-rollback';
  exception when others then
    if sqlerrm <> 'v138-rollback' then raise; end if;
  end;
  insert into _v138_results
  -- an empty result compares as NULL: count it as a failure, never a blank
  select (j->>'n')::int, j->>'c', coalesce((j->>'p')::boolean, false), coalesce(j->>'d', '(none)') from jsonb_array_elements(res) j;
end $$;
select * from _v138_results order by n;
