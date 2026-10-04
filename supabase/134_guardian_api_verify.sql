-- 134_guardian_api_verify.sql
--
-- Checks for 134_guardian_api.sql. Every query stands alone: select one, run it,
-- read the comment above it for the expected result.
-- V1-V3 are read-only. V4 writes throwaway rows inside a block that it rolls
-- back before showing results, so nothing persists.

-- ---------------------------------------------------------------------------
-- V1. Notification CHECKs: the old values plus 'guardian_request' and
--     'guardianship'. Expected: 2 rows, both has_new = true and both
--     kept_old = true.
-- ---------------------------------------------------------------------------
select c.conname,
       pg_get_constraintdef(c.oid) as definition,
       pg_get_constraintdef(c.oid) like '%''guardian_request''%'
         or pg_get_constraintdef(c.oid) like '%''guardianship''%'                     as has_new,
       case c.conname
         when 'notifications_type_check' then
           pg_get_constraintdef(c.oid) ~ 'photo_approved' and pg_get_constraintdef(c.oid) ~ 'photo_rejected'
           and pg_get_constraintdef(c.oid) ~ 'feedback_received' and pg_get_constraintdef(c.oid) ~ '''promotion'''
           and pg_get_constraintdef(c.oid) ~ 'admin_message'
         else
           pg_get_constraintdef(c.oid) ~ 'photo_approval' and pg_get_constraintdef(c.oid) ~ '''feedback'''
           and pg_get_constraintdef(c.oid) ~ '''promotion''' and pg_get_constraintdef(c.oid) ~ 'admin_message'
       end                                                                             as kept_old
  from pg_constraint c
 where c.conrelid = 'public.notifications'::regclass
   and c.conname in ('notifications_type_check', 'notifications_related_entity_type_check')
 order by c.conname;

-- ---------------------------------------------------------------------------
-- V2. Client RPCs: callable by authenticated, not by anon, all SECURITY
--     DEFINER. Expected: 6 rows, authenticated = true, anon = false,
--     security_definer = true.
-- ---------------------------------------------------------------------------
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       p.prosecdef                                               as security_definer
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('guardian_add','guardian_link_member','guardian_request',
                     'guardian_request_decide','guardian_revoke','kid_guardians')
 order by p.proname;

-- ---------------------------------------------------------------------------
-- V2b. guardian_request returns ONLY id and status. Expected: 1 row,
--      result = 'TABLE(id uuid, status text)'.
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_result(p.oid) as result
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.proname = 'guardian_request';

-- ---------------------------------------------------------------------------
-- V3. Internal helpers: not callable by any client role.
--     Expected: 9 rows, all false.
-- ---------------------------------------------------------------------------
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('anon', p.oid, 'execute')          as anon
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('_unit_staff_user_ids','_whitelist_ensure','_guardian_can_manage',
                     '_guardian_emails','_guardian_find_live','_guardian_account_for',
                     '_guardian_no_active_primary','_guardian_check_lengths','_guardian_approve')
 order by p.proname;

-- ---------------------------------------------------------------------------
-- V4. Scenario proof, on throwaway kids, impersonating real accounts through
--     request.jwt.claims (what auth.uid() reads). Every write happens inside
--     an inner block that is rolled back before the results are stored:
--     NOTHING PERSISTS (notifications included; the temp table lives only for
--     this session). Run the three statements together.
--     Needs: one unit owner, and two accounts that are neither instructors nor
--     owners, both with an email (public.users joined to auth.users).
--     Expected: 12 rows, every pass = true.
-- ---------------------------------------------------------------------------
create temp table if not exists _v134_results (n int, check_name text, pass boolean, detail text);
truncate _v134_results;
do $$
declare
  v_owner uuid; v_unit uuid; u1 uuid; e1 text; u2 uuid;
  k uuid; k2 uuid; g public.guardianships; g2 public.guardianships; rid uuid;
  v_new text := 'zz-v134-' || substr(md5(random()::text), 1, 10) || '@example.invalid';
  v_wl  text := 'zz-v134-wl-' || substr(md5(random()::text), 1, 10) || '@example.invalid';
  n_staff int; n_notif int; st text; st2 text; ok boolean; v_err text;
  q_id uuid; q_status text; e2 text; g_pend uuid;
  res jsonb := '[]'::jsonb;
  -- run as: set the JWT subject for this transaction only
  as_user text := 'select set_config(''request.jwt.claims'', json_build_object(''sub'', %L)::text, true), set_config(''request.jwt.claim.sub'', %L, true)';
begin
  select uo.user_id, uo.unit_id into v_owner, v_unit
    from public.unit_owners uo join auth.users au on au.id = uo.user_id
   order by uo.added_at limit 1;
  -- u1 / u2 must be plain members: not instructors and not owners, or the
  -- staff branch of the RPCs would answer instead of the guardian branch.
  select u.id, lower(btrim(au.email)) into u1, e1
    from public.users u join auth.users au on au.id = u.id
   where coalesce(u.role, '') <> 'instructor'
     and not exists (select 1 from public.unit_owners o where o.user_id = u.id)
     and nullif(btrim(au.email), '') is not null
   order by u.id limit 1;
  select u.id into u2
    from public.users u join auth.users au on au.id = u.id
   where coalesce(u.role, '') <> 'instructor'
     and not exists (select 1 from public.unit_owners o where o.user_id = u.id)
     and u.id <> u1
     and nullif(btrim(au.email), '') is not null
   order by u.id limit 1;
  select lower(btrim(au.email)) into e2 from auth.users au where au.id = u2;
  if v_owner is null or u1 is null or u2 is null then
    raise exception 'V4 needs one unit owner and two member accounts that are not staff';
  end if;

  begin
    execute format(as_user, v_owner, v_owner);
    insert into public.students (full_name, prog, unit_id) values ('zz v134 kid', 'kids', v_unit) returning id into k;

    -- 1 add with an existing account -> active
    g := public.guardian_add(k, upper(e1), 'Guardian One', 'Parent');
    res := res || jsonb_build_object('n',1,'c','add existing account -> active','p',
             g.status = 'active' and g.guardian_user_id = u1 and g.origin = 'staff' and g.approved_by = v_owner,
             'd', g.status || '/' || g.origin);

    -- 2 add with a new email -> pending + whitelist parent row
    g := public.guardian_add(k, v_new, 'New Person', null);
    g_pend := g.id;
    select role into st from public.whitelist where lower(email) = v_new;
    res := res || jsonb_build_object('n',2,'c','add new email -> pending + whitelist','p',
             g.status = 'pending' and g.invite_email::text = v_new and st = 'parent',
             'd', g.status || ' / whitelist ' || coalesce(st, 'none'));

    -- 3 an existing whitelist row keeps its role
    insert into public.whitelist (email, role) values (v_wl, 'student');
    g := public.guardian_add(k, v_wl, null, null);
    select role into st from public.whitelist where email = v_wl;
    res := res || jsonb_build_object('n',3,'c','existing whitelist role unchanged','p',
             g.status = 'pending' and st = 'student', 'd', 'role ' || st);

    -- 4 a guardian requests -> requested + one notification per unit staff member
    execute format(as_user, u1, u1);
    select x.id, x.status into q_id, q_status
      from public.guardian_request(k, 'zz-v134-req1@example.invalid', 'Grandma', 'Grandparent') x;
    select * into g from public.guardianships where id = q_id;
    n_staff := cardinality(public._unit_staff_user_ids(v_unit));
    select count(*) into n_notif from public.notifications
     where type = 'guardian_request' and related_entity_type = 'guardianship' and related_entity_id = g.id;
    res := res || jsonb_build_object('n',4,'c','guardian request -> requested + staff notified','p',
             g.status = 'requested' and g.origin = 'parent_request' and g.created_by = u1
             and n_staff >= 1 and n_notif = n_staff,
             'd', g.status || ', ' || n_notif || ' of ' || n_staff || ' staff notified');
    rid := g.id;

    -- 5 a non-guardian is refused
    execute format(as_user, u2, u2);
    ok := false;
    begin
      perform public.guardian_request(k, 'zz-v134-req2@example.invalid', null, null);
    exception when others then ok := true; v_err := sqlerrm;
    end;
    res := res || jsonb_build_object('n',5,'c','non-guardian request refused','p', ok, 'd', coalesce(v_err, 'not refused'));

    -- 6 approve (no account -> pending) and decline
    execute format(as_user, u1, u1);
    select x.id into q_id from public.guardian_request(k, 'zz-v134-req3@example.invalid', 'Uncle', null) x;
    select * into g2 from public.guardianships where id = q_id;
    execute format(as_user, v_owner, v_owner);
    g := public.guardian_request_decide(rid, true);
    g2 := public.guardian_request_decide(g2.id, false);
    res := res || jsonb_build_object('n',6,'c','approve -> pending (no account); decline -> declined','p',
             g.status = 'pending' and g.approved_by = v_owner and g2.status = 'declined'
             and exists (select 1 from public.whitelist where email = 'zz-v134-req1@example.invalid'),
             'd', g.status || ' / ' || g2.status);

    -- 7 revoke a legacy row clears the legacy column and stays revoked
    insert into public.students (full_name, prog, unit_id, parent_user_id)
      values ('zz v134 kid 2', 'kids', v_unit, u2) returning id into k2;
    select * into g from public.guardianships where student_id = k2 and guardian_user_id = u2;
    g := public.guardian_revoke(g.id);
    update public.students set parent2_email = null, parent_name = 'zz touch' where id = k2;   -- a later staff save
    select status into st from public.guardianships where id = g.id;
    select string_agg(status, ',') into st2 from public.guardianships
     where student_id = k2 and guardian_user_id = u2 and status in ('requested','pending','active');
    res := res || jsonb_build_object('n',7,'c','revoke legacy row clears column, stays revoked','p',
             g.origin = 'legacy_sync' and st = 'revoked' and g.revoked_by = v_owner
             and (select parent_user_id from public.students where id = k2) is null and st2 is null,
             'd', g.origin || ' -> ' || st || ', live again: ' || coalesce(st2, 'none'));

    -- 8 a guardian caller never sees emails
    execute format(as_user, u1, u1);
    select bool_and(email is null and origin is null and created_at is null), count(*)
      into ok, n_notif from public.kid_guardians(k);
    res := res || jsonb_build_object('n',8,'c','kid_guardians hides email from a guardian','p',
             ok and n_notif >= 3, 'd', n_notif || ' rows');

    -- 9 a dedupe hit against ANOTHER guardian's row returns only its id + status
    execute format(as_user, u1, u1);
    select x.id, x.status into q_id, q_status from public.guardian_request(k, upper(v_new), null, null) x;
    res := res || jsonb_build_object('n',9,'c','request dedupe returns only id + status','p',
             q_id = g_pend and q_status = 'pending'
             and pg_get_function_result('public.guardian_request(uuid,text,text,text)'::regprocedure) = 'TABLE(id uuid, status text)',
             'd', q_status || ' / ' || pg_get_function_result('public.guardian_request(uuid,text,text,text)'::regprocedure));

    -- 10 guardian_add on a requested row approves it: account -> active, none -> pending
    select x.id into q_id from public.guardian_request(k, e2, 'Second Member', null) x;
    select x.id into rid  from public.guardian_request(k, 'zz-v134-req9@example.invalid', 'Nobody Yet', null) x;
    execute format(as_user, v_owner, v_owner);
    g  := public.guardian_add(k, e2, 'ignored name', null);
    g2 := public.guardian_add(k, 'zz-v134-req9@example.invalid', null, null);
    res := res || jsonb_build_object('n',10,'c','add on requested row approves it','p',
             g.id = q_id and g.status = 'active' and g.guardian_user_id = u2 and g.approved_by = v_owner
             and g2.id = rid and g2.status = 'pending' and g2.approved_by = v_owner
             and exists (select 1 from public.whitelist where email = 'zz-v134-req9@example.invalid'),
             'd', g.status || ' / ' || g2.status);

    -- 11 over-length name and relationship refused (add and request)
    ok := true; v_err := '';
    begin perform public.guardian_add(k, 'zz-len1@example.invalid', repeat('n', 81), null); ok := false;
    exception when others then v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.guardian_add(k, 'zz-len2@example.invalid', null, repeat('r', 41)); ok := false;
    exception when others then v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.guardian_add(k, repeat('e', 250) || '@x.io', null, null); ok := false;
    exception when others then v_err := v_err || sqlerrm || ' | '; end;
    execute format(as_user, u1, u1);
    begin perform public.guardian_request(k, 'zz-len3@example.invalid', repeat('n', 81), null); ok := false;
    exception when others then v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.guardian_request(k, 'zz-len4@example.invalid', null, repeat('r', 41)); ok := false;
    exception when others then v_err := v_err || sqlerrm; end;
    res := res || jsonb_build_object('n',11,'c','over-length name / relationship / email refused','p', ok, 'd', v_err);

    -- 12 at the limit is accepted (80 / 40 after trim), empty stays null
    execute format(as_user, v_owner, v_owner);
    g := public.guardian_add(k, 'zz-len5@example.invalid', '  ' || repeat('n', 80) || '  ', repeat('r', 40));
    g2 := public.guardian_add(k, 'zz-len6@example.invalid', '   ', '');
    res := res || jsonb_build_object('n',12,'c','limits are inclusive; blank name/relationship -> null','p',
             length(g.guardian_name) = 80 and length(g.relationship) = 40
             and g2.guardian_name is null and g2.relationship is null, 'd', '');

    raise exception 'v134-rollback';
  exception when others then
    if sqlerrm <> 'v134-rollback' then raise; end if;
  end;

  insert into _v134_results
  select (x->>'n')::int, x->>'c', (x->>'p')::boolean, x->>'d' from jsonb_array_elements(res) x;
end $$;
select * from _v134_results order by n;
