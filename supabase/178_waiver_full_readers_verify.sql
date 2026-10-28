-- 178_waiver_full_readers_verify.sql
--
-- Run AFTER 178, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/178_waiver_full_readers_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the Zz178 units, users,
-- students, guardianship, trial and waivers included). Every test prints
-- "PASS n ..." (NOTICE, and the rows selected at the end); the first failure stops
-- it with "FAIL n ...".
-- Fixtures: unit Zz178 A (owner o = an owner NOT in the readers, instructor i),
-- unit Zz178 B (instructor ib, student x = a stranger to A). Student S1 in A
-- (user st, parent pa, active guardian gd) with two waivers: W1 older (asthma,
-- 'Zz178 old') and W2 latest (allergies, 'Zz178 latest', emergency contact,
-- signature, answers.dob). Trial T1 in A with waiver WT (answers.dob 2010-05-06,
-- answers.gender M).
-- Readers are the real 3 users (resolved by email here, in the test only).

begin;

create temp table v178 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v178 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- a query as a user, its rows as one jsonb array (or "ERR <message>"); the role
-- and claims of the call are undone with its subtransaction
create function pg_temp.as_json(u uuid, q text) returns text language plpgsql as $f$
declare j jsonb;
begin
  begin
    perform pg_temp.v_as(u);
    execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (' || q || ') x' into j;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return j::text;
  exception when others then
    return 'ERR ' || sqlerrm;
  end;
end $f$;

do $$
declare
  ua uuid; ub uuid;
  o uuid := gen_random_uuid(); i uuid := gen_random_uuid(); ib uuid := gen_random_uuid();
  st uuid := gen_random_uuid(); pa uuid := gen_random_uuid(); gd uuid := gen_random_uuid(); x uuid := gen_random_uuid();
  s1 uuid; sx uuid; t1 uuid; w1 uuid; w2 uuid; wt uuid;
  r_pat uuid; r_mar uuid; r_adm uuid; john uuid;
  readers uuid[];
  v text; v2 text;
  pa_list uuid[];
  q_doc_s text; q_doc_t text; q_alert text; q_direct text; q_link text; q_link_direct text;
  p uuid;
begin
  select id into r_pat from auth.users where lower(email) = 'info@mybjj.com.au';
  select id into r_mar from auth.users where lower(email) = 'mariobjj@hotmail.com';
  select id into r_adm from auth.users where lower(email) = 'admin.mybjj@gmail.com';
  select id into john  from auth.users where lower(email) = 'me@johnluhr.com.au';

  -- fixtures --------------------------------------------------------------
  insert into public.units (name) values ('Zz178 A') returning id into ua;
  insert into public.units (name) values ('Zz178 B') returning id into ub;
  insert into auth.users (id, email)
  select y, 'zz178-' || y::text || '@example.invalid' from unnest(array[o, i, ib, st, pa, gd, x]) y;
  insert into public.users (id, email, full_name, role, status, unit_id, active_unit_id)
  select z.id, 'zz178-' || z.id::text || '@example.invalid', z.nm, z.role, 'approved', z.u, z.u
    from (values (o, 'Zz178 Owner', 'instructor', ua), (i, 'Zz178 Instructor', 'instructor', ua),
                 (ib, 'Zz178 Instructor B', 'instructor', ub), (st, 'Zz178 Student', 'student', ua),
                 (pa, 'Zz178 Parent', 'parent', ua), (gd, 'Zz178 Guardian', 'parent', ua),
                 (x, 'Zz178 Stranger', 'student', ub)) z(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id, active_unit_id = excluded.active_unit_id;
  update public.units set owner_user_id = o where id = ua;
  insert into public.students (full_name, unit_id, user_id, parent_user_id) values ('Zz178 Student', ua, st, pa) returning id into s1;
  insert into public.students (full_name, unit_id, user_id) values ('Zz178 Stranger', ub, x) returning id into sx;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, access)
    values (s1, gd, 'active', 'staff', o, 'view');
  insert into public.trial_bookings (first_name, last_name, unit_id) values ('Zz178', 'Trial', ua) returning id into t1;
  insert into public.health_waivers (student_id, unit_id, participant_name, signed_by_name, waiver_text_version,
                                     signed_at, has_asthma, safety_notes, answers)
    values (s1, ua, 'Zz178 Student', 'Zz178 Student', 'zz178', now() - interval '30 days', true, 'Zz178 old', '{"dob":"2001-02-03"}')
    returning id into w1;
  insert into public.health_waivers (student_id, unit_id, participant_name, signed_by_name, waiver_text_version,
                                     signed_at, has_allergies, safety_notes, emergency_name, emergency_phone, signature_path, answers)
    values (s1, ua, 'Zz178 Student', 'Zz178 Student', 'zz178', now() - interval '1 day', true, 'Zz178 latest',
            'Zz178 EC', '0400 000 178', 'signature/zz178.png', '{"dob":"2001-02-03","gender":"F"}')
    returning id into w2;
  insert into public.health_waivers (trial_booking_id, unit_id, participant_name, signed_by_name, waiver_text_version,
                                     signed_at, answers, emergency_name)
    values (t1, ua, 'Zz178 Trial', 'Zz178 Trial', 'zz178', now(), '{"dob":"2010-05-06","gender":"M"}', 'Zz178 trial EC')
    returning id into wt;

  -- 1. the readers are exactly the 3 users --------------------------------
  select array_agg(user_id order by user_id) into readers from public.waiver_full_readers;
  if readers is distinct from (select array_agg(u order by u) from unnest(array[r_pat, r_mar, r_adm]) u)
     or r_pat is null or r_mar is null or r_adm is null then
    raise exception 'FAIL 1 readers: %', readers;
  end if;
  perform pg_temp.ok('PASS 1 waiver_full_readers = Patricia, Mario, admin (3 rows, by user_id)');

  -- 2. can_read_full_waiver -------------------------------------------------
  v := '';
  foreach p in array array[r_pat, r_mar, r_adm, i, o, john, st, gd] loop
    v := v || pg_temp.as_json(p, 'select public.can_read_full_waiver() as c') || ' ';
  end loop;
  if v <> '[{"c": true}] [{"c": true}] [{"c": true}] [{"c": false}] [{"c": false}] [{"c": false}] [{"c": false}] [{"c": false}] ' then
    raise exception 'FAIL 2 can_read_full_waiver: %', v;
  end if;
  perform pg_temp.ok('PASS 2 can_read_full_waiver: true for the 3 readers; false for an instructor, an owner not in the list (fixture and John), a member, a guardian');

  -- 3. waiver_document for a student -----------------------------------------
  q_doc_s := format('select id, emergency_name, signature_path, answers ->> %L as dob, safety_notes from public.waiver_document(p_student => %L)', 'dob', s1);
  foreach p in array array[r_pat, r_mar, r_adm, st, pa, gd] loop
    v := pg_temp.as_json(p, q_doc_s);
    if v <> format('[{"id": "%s", "dob": "2001-02-03", "safety_notes": "Zz178 latest", "emergency_name": "Zz178 EC", "signature_path": "signature/zz178.png"}]', w2) then
      raise exception 'FAIL 3 waiver_document as % : %', p, v;
    end if;
  end loop;
  perform pg_temp.ok('PASS 3 waiver_document(student) = the LATEST waiver, full (emergency, signature, answers) for a reader, the student, the parent, the guardian');

  v := '';
  foreach p in array array[i, o, john, ib, x] loop
    v := v || pg_temp.as_json(p, q_doc_s) || ' ';
  end loop;
  if v <> '[] [] [] [] [] ' then raise exception 'FAIL 4 waiver_document leaks: %', v; end if;
  perform pg_temp.ok('PASS 4 waiver_document(student) empty for an instructor of the unit, an owner not in the list (fixture and John), another unit''s instructor, a stranger');

  -- 5. waiver_document for a trial: readers only -------------------------------
  q_doc_t := format('select id, emergency_name from public.waiver_document(p_trial => %L)', t1);
  v := pg_temp.as_json(r_pat, q_doc_t);
  if v <> format('[{"id": "%s", "emergency_name": "Zz178 trial EC"}]', wt) then raise exception 'FAIL 5 trial doc reader: %', v; end if;
  v := '';
  foreach p in array array[i, o, john, st] loop
    v := v || pg_temp.as_json(p, q_doc_t) || ' ';
  end loop;
  v := v || pg_temp.as_json(r_pat, format('select id from public.waiver_document(%L, %L)', s1, t1))
         || pg_temp.as_json(r_pat, 'select id from public.waiver_document()');
  if v <> '[] [] [] [] [][]' then raise exception 'FAIL 5 trial doc non-reader / bad args: %', v; end if;
  perform pg_temp.ok('PASS 5 waiver_document(trial) only for a reader; empty for an instructor, a non-reader owner, a member; both or no key -> empty');

  -- 6. waiver_alerts = what each persona reads directly today -----------------
  q_alert := format('select * from public.waiver_alerts(%L)', s1);
  q_direct := format('select has_asthma, has_heart_condition, has_diabetes, has_epilepsy, is_pregnant, takes_medication, has_allergies, has_recent_injury, safety_notes, signed_at from public.health_waivers where student_id = %L order by signed_at desc limit 1', s1);
  foreach p in array array[i, o, john, r_pat, st, pa, gd, ib, x] loop
    v := pg_temp.as_json(p, q_alert); v2 := pg_temp.as_json(p, q_direct);
    if v is distinct from v2 or v like 'ERR%' then raise exception 'FAIL 6 alerts as %: rpc % direct %', p, v, v2; end if;
  end loop;
  v := pg_temp.as_json(i, q_alert);
  if jsonb_array_length(v::jsonb) <> 1 or v::jsonb -> 0 ->> 'has_allergies' <> 'true' or v::jsonb -> 0 ->> 'has_asthma' <> 'false'
     or v::jsonb -> 0 ->> 'safety_notes' <> 'Zz178 latest' then
    raise exception 'FAIL 6 alerts content: %', v;
  end if;
  if pg_temp.as_json(ib, q_alert) <> '[]' or pg_temp.as_json(x, q_alert) <> '[]' then raise exception 'FAIL 6 alerts stranger'; end if;
  perform pg_temp.ok('PASS 6 waiver_alerts = today''s direct read (latest flags + notes + signed_at) for instructor, owners, reader, student, parent, guardian; nothing for another unit''s instructor or a stranger');

  -- 7. trial link check and dob: staff only -----------------------------------
  q_link := format('select * from public.waiver_trial_link_check(%L)', t1);
  q_link_direct := format('select id, student_id from public.health_waivers where trial_booking_id = %L', t1);
  foreach p in array array[i, o, r_pat, ib, st, x] loop
    v := pg_temp.as_json(p, q_link); v2 := pg_temp.as_json(p, q_link_direct);
    if v is distinct from v2 then raise exception 'FAIL 7 link check as %: rpc % direct %', p, v, v2; end if;
  end loop;
  if pg_temp.as_json(i, q_link) <> format('[{"id": "%s", "student_id": null}]', wt) or pg_temp.as_json(st, q_link) <> '[]' or pg_temp.as_json(ib, q_link) <> '[]' then
    raise exception 'FAIL 7 link check content';
  end if;
  v := pg_temp.as_json(i, format('select * from public.waiver_trial_prefill(%L)', t1)) || pg_temp.as_json(o, format('select * from public.waiver_trial_prefill(%L)', t1))
    || pg_temp.as_json(st, format('select * from public.waiver_trial_prefill(%L)', t1)) || pg_temp.as_json(ib, format('select * from public.waiver_trial_prefill(%L)', t1));
  if v <> '[{"dob": "2010-05-06", "gender": "M"}][{"dob": "2010-05-06", "gender": "M"}][][]' then raise exception 'FAIL 7 prefill: %', v; end if;
  perform pg_temp.ok('PASS 7 waiver_trial_link_check = today''s (id, student_id) read per persona; waiver_trial_prefill = (answers.dob, answers.gender) for staff of the unit / owner, no row for a member or another unit''s instructor');

  -- 8. grants -----------------------------------------------------------------
  if has_function_privilege('anon', 'public.can_read_full_waiver()', 'execute')
     or has_function_privilege('anon', 'public.waiver_document(uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.waiver_alerts(uuid)', 'execute')
     or has_function_privilege('anon', 'public.waiver_trial_link_check(uuid)', 'execute')
     or has_function_privilege('anon', 'public.waiver_trial_prefill(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.waiver_trial_prefill(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.waiver_document(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.waiver_alerts(uuid)', 'execute') then
    raise exception 'FAIL 8 function grants';
  end if;
  v := pg_temp.as_json(r_pat, 'select user_id from public.waiver_full_readers');
  if v not like 'ERR permission denied%' then raise exception 'FAIL 8 readers table readable by a client: %', v; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.waiver_full_readers'::regclass)
     or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'waiver_full_readers') then
    raise exception 'FAIL 8 readers RLS';
  end if;
  if exists (select 1 from pg_proc where proname in ('can_read_full_waiver', 'waiver_document', 'waiver_alerts', 'waiver_trial_link_check', 'waiver_trial_prefill')
              and (not prosecdef or proconfig is distinct from array['search_path=public'])) then
    raise exception 'FAIL 8 security definer / search_path';
  end if;
  perform pg_temp.ok('PASS 8 the 5 functions: SECURITY DEFINER, search_path=public, execute for authenticated not anon; waiver_full_readers RLS on, no policies, no client read');

  -- 9. nothing locked yet: the old app's direct reads still work --------------
  v := pg_temp.as_json(i, format('select emergency_name, answers ->> %L as dob from public.health_waivers where id = %L', 'dob', w2));
  if v <> '[{"dob": "2001-02-03", "emergency_name": "Zz178 EC"}]' then raise exception 'FAIL 9 old direct read: %', v; end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'health_waivers' and policyname = 'hw_select'
              and qual <> '(is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = health_waivers.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))) OR (student_id = ANY (( SELECT guardian_student_ids() AS guardian_student_ids)::uuid[])))') then
    raise exception 'FAIL 9 hw_select changed';
  end if;
  perform pg_temp.ok('PASS 9 nothing revoked: an instructor still reads every column directly (today''s app keeps working); hw_select unchanged');
end $$;

select n, line from v178 order by n;

rollback;
