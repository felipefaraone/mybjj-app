-- 179_waiver_lock_verify.sql
--
-- Run AFTER 178 and 179, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/179_waiver_lock_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the Zz179 units, users,
-- students, guardianship, trial, waivers and storage object included). Every test
-- prints "PASS n ..." (NOTICE, and the rows selected at the end); the first
-- failure stops it with "FAIL n ...".
-- Fixtures: unit Zz179 A (owner o = an owner NOT in the readers, instructor i),
-- unit Zz179 B (stranger x). Student S1 in A (user st, parent pa, active guardian
-- gd) with waiver W1 and its signature object 'signature/<W1>.png' in the waivers
-- bucket; trial T1 in A with waiver WT (no student yet). Reader = Patricia (real).

begin;

create temp table v179 (n serial, line text);
create function pg_temp.ok(p_line text) returns void language plpgsql as $f$
begin
  insert into v179 (line) values (p_line);
  raise notice '%', p_line;
end $f$;
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
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
-- a write as a user: rows affected, or "ERR <message>"
create function pg_temp.as_exec(u uuid, q text) returns text language plpgsql as $f$
declare n integer;
begin
  begin
    perform pg_temp.v_as(u);
    execute q;
    get diagnostics n = row_count;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return n::text;
  exception when others then
    return 'ERR ' || sqlerrm;
  end;
end $f$;

do $$
declare
  ua uuid; ub uuid;
  o uuid := gen_random_uuid(); i uuid := gen_random_uuid();
  st uuid := gen_random_uuid(); pa uuid := gen_random_uuid(); gd uuid := gen_random_uuid(); x uuid := gen_random_uuid();
  s1 uuid; t1 uuid; w1 uuid; wt uuid;
  r_pat uuid; john uuid; evelin uuid;
  p uuid; c text; v text; sig text;
  sens text[] := array['answers', 'emergency_name', 'emergency_phone', 'emergency_relationship', 'signature_path',
                       'signed_by_name', 'signed_by_relationship', 'participant_name', 'waiver_text_version', '*'];
  alert_cols text := 'id, trial_booking_id, student_id, unit_id, is_minor, signed_at, created_at, has_asthma, has_heart_condition, has_diabetes, has_epilepsy, is_pregnant, takes_medication, has_allergies, has_recent_injury, safety_notes';
begin
  select id into r_pat  from auth.users where lower(email) = 'info@mybjj.com.au';
  select id into john   from auth.users where lower(email) = 'me@johnluhr.com.au';
  select id into evelin from auth.users where lower(email) = 'evelinalara@outlook.com';

  -- fixtures --------------------------------------------------------------
  insert into public.units (name) values ('Zz179 A') returning id into ua;
  insert into public.units (name) values ('Zz179 B') returning id into ub;
  insert into auth.users (id, email)
  select y, 'zz179-' || y::text || '@example.invalid' from unnest(array[o, i, st, pa, gd, x]) y;
  insert into public.users (id, email, full_name, role, status, unit_id, active_unit_id)
  select z.id, 'zz179-' || z.id::text || '@example.invalid', z.nm, z.role, 'approved', z.u, z.u
    from (values (o, 'Zz179 Owner', 'instructor', ua), (i, 'Zz179 Instructor', 'instructor', ua),
                 (st, 'Zz179 Student', 'student', ua), (pa, 'Zz179 Parent', 'parent', ua),
                 (gd, 'Zz179 Guardian', 'parent', ua), (x, 'Zz179 Stranger', 'student', ub)) z(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id, active_unit_id = excluded.active_unit_id;
  update public.units set owner_user_id = o where id = ua;
  insert into public.students (full_name, unit_id, user_id, parent_user_id) values ('Zz179 Student', ua, st, pa) returning id into s1;
  insert into public.students (full_name, unit_id, user_id) values ('Zz179 Stranger', ub, x);
  insert into public.guardianships (student_id, guardian_user_id, status, origin, created_by, access)
    values (s1, gd, 'active', 'staff', o, 'view');
  insert into public.trial_bookings (first_name, last_name, unit_id) values ('Zz179', 'Trial', ua) returning id into t1;
  insert into public.health_waivers (student_id, unit_id, participant_name, signed_by_name, waiver_text_version,
                                     has_epilepsy, safety_notes, emergency_name, answers)
    values (s1, ua, 'Zz179 Student', 'Zz179 Student', 'zz179', true, 'Zz179 notes', 'Zz179 EC', '{"dob":"1999-09-09"}')
    returning id into w1;
  sig := 'signature/' || w1::text || '.png';
  update public.health_waivers set signature_path = sig where id = w1;
  insert into public.health_waivers (trial_booking_id, unit_id, participant_name, signed_by_name, waiver_text_version, answers)
    values (t1, ua, 'Zz179 Trial', 'Zz179 Trial', 'zz179', '{"dob":"2012-12-12"}')
    returning id into wt;
  insert into storage.objects (bucket_id, name) values ('waivers', sig);

  -- 1. sensitive columns: permission denied for every client ------------------
  foreach p in array array[i, o, john, evelin, r_pat, st, gd] loop
    foreach c in array sens loop
      v := pg_temp.as_json(p, format('select %s from public.health_waivers where student_id = %L', c, s1));
      if v not like 'ERR permission denied for table health_waivers%' then
        raise exception 'FAIL 1 % read % directly: %', p, c, v;
      end if;
    end loop;
  end loop;
  perform pg_temp.ok('PASS 1 answers / emergency_* / signature_path / signed_by_* / participant_name / waiver_text_version / select * from health_waivers: permission denied for an instructor, non-reader owners (fixture, John, Evelin), a reader (Patricia), the member, a guardian');

  -- 2. the alert columns still read directly, under hw_select's row rule -------
  v := pg_temp.as_json(i, format('select %s from public.health_waivers where student_id = %L', alert_cols, s1));
  if v like 'ERR%' or jsonb_array_length(v::jsonb) <> 1 or v::jsonb -> 0 ->> 'safety_notes' <> 'Zz179 notes' or v::jsonb -> 0 ->> 'has_epilepsy' <> 'true' then
    raise exception 'FAIL 2 instructor alert columns: %', v;
  end if;
  foreach p in array array[o, john, st, gd, pa] loop
    v := pg_temp.as_json(p, format('select %s from public.health_waivers where student_id = %L', alert_cols, s1));
    if v like 'ERR%' then raise exception 'FAIL 2 alert columns as %: %', p, v; end if;
  end loop;
  if pg_temp.as_json(x, format('select id from public.health_waivers where student_id = %L', s1)) <> '[]' then
    raise exception 'FAIL 2 stranger sees the row';
  end if;
  perform pg_temp.ok('PASS 2 the 16 alert-safe columns still select directly (instructor of the unit, owners, member, parent, guardian); a stranger still sees no row');

  -- 3. the RPCs still work after the lock -------------------------------------
  v := pg_temp.as_json(r_pat, format('select id, emergency_name, signature_path, answers ->> %L as dob from public.waiver_document(p_student => %L)', 'dob', s1));
  if v <> format('[{"id": "%s", "dob": "1999-09-09", "emergency_name": "Zz179 EC", "signature_path": "%s"}]', w1, sig) then
    raise exception 'FAIL 3 reader document: %', v;
  end if;
  if pg_temp.as_json(st, format('select id from public.waiver_document(p_student => %L)', s1)) <> format('[{"id": "%s"}]', w1)
     or pg_temp.as_json(gd, format('select id from public.waiver_document(p_student => %L)', s1)) <> format('[{"id": "%s"}]', w1)
     or pg_temp.as_json(i, format('select id from public.waiver_document(p_student => %L)', s1)) <> '[]'
     or pg_temp.as_json(john, format('select id from public.waiver_document(p_student => %L)', s1)) <> '[]'
     or pg_temp.as_json(r_pat, format('select id from public.waiver_document(p_trial => %L)', t1)) <> format('[{"id": "%s"}]', wt) then
    raise exception 'FAIL 3 document per persona';
  end if;
  v := pg_temp.as_json(i, format('select safety_notes, has_epilepsy from public.waiver_alerts(%L)', s1));
  if v <> '[{"has_epilepsy": true, "safety_notes": "Zz179 notes"}]' then raise exception 'FAIL 3 alerts: %', v; end if;
  perform pg_temp.ok('PASS 3 waiver_document still full for a reader, the member, a guardian (trial: reader); empty for an instructor and John; waiver_alerts still works for the instructor');

  -- 4. storage: the signature image ------------------------------------------
  v := '';
  foreach p in array array[r_pat, st, pa, gd, i, o, john, evelin, x] loop
    v := v || pg_temp.as_json(p, format('select count(*) as n from storage.objects where bucket_id = %L and name = %L', 'waivers', sig)) || ' ';
  end loop;
  if v <> '[{"n": 1}] [{"n": 1}] [{"n": 1}] [{"n": 1}] [{"n": 0}] [{"n": 0}] [{"n": 0}] [{"n": 0}] [{"n": 0}] ' then
    raise exception 'FAIL 4 storage read (reader, member, parent, guardian, instructor, owner, John, Evelin, stranger): %', v;
  end if;
  perform pg_temp.ok('PASS 4 waivers bucket signature: readable by the reader, the member, the parent, the guardian; not by an instructor, non-reader owners (fixture, John, Evelin) or a stranger');

  -- 5. other storage policies, anon, service_role, writes ----------------------
  if (select md5(string_agg(policyname || cmd || coalesce(qual, '') || coalesce(with_check, ''), '|' order by policyname))
        from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname <> 'waivers_read')
       is distinct from '4fd720c4037146b0b81a1ef77f66713e' then
    raise exception 'FAIL 5 other storage policies changed';
  end if;
  if exists (select 1 from pg_attribute a where a.attrelid = 'public.health_waivers'::regclass and a.attnum > 0 and not a.attisdropped
              and has_column_privilege('anon', 'public.health_waivers', a.attname, 'select'))
     or not has_table_privilege('service_role', 'public.health_waivers', 'select') then
    raise exception 'FAIL 5 anon / service_role grants';
  end if;
  if (select md5(string_agg(policyname || cmd || coalesce(qual, '') || coalesce(with_check, ''), '|' order by policyname))
        from pg_policies where schemaname = 'public' and tablename = 'health_waivers')
     is distinct from (select md5(string_agg(x.n || x.c || x.q || x.w, '|' order by x.n)) from (values
        ('hw_delete', 'DELETE', 'is_admin()', ''),
        ('hw_insert', 'INSERT', '', '(is_admin() OR is_staff())'),
        ('hw_select', 'SELECT', '(is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = health_waivers.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))) OR (student_id = ANY (( SELECT guardian_student_ids() AS guardian_student_ids)::uuid[])))', ''),
        ('hw_update', 'UPDATE', 'is_admin()', 'is_admin()')) x(n, c, q, w)) then
    raise exception 'FAIL 5 hw_* policies changed';
  end if;
  perform pg_temp.ok('PASS 5 avatars_* and waivers_delete/_update/_write unchanged; anon reads no column; service_role (Edge Functions) keeps SELECT; hw_select / hw_insert / hw_update / hw_delete unchanged');

  -- 6. the trial conversion write still lands for an owner ---------------------
  v := pg_temp.as_exec(o, format('update public.health_waivers set student_id = %L where trial_booking_id = %L and student_id is null', s1, t1));
  if v <> '1' then raise exception 'FAIL 6 owner conversion update: %', v; end if;
  v := pg_temp.as_json(o, format('select * from public.waiver_trial_link_check(%L)', t1));
  if v <> format('[{"id": "%s", "student_id": "%s"}]', wt, s1) then raise exception 'FAIL 6 link check after update: %', v; end if;
  v := pg_temp.as_exec(i, format('update public.health_waivers set student_id = null where id = %L', wt));
  if v <> '0' then raise exception 'FAIL 6 instructor update should be an RLS no-op: %', v; end if;
  perform pg_temp.ok('PASS 6 conversion path: an owner''s UPDATE ... WHERE trial_booking_id / student_id still lands and waiver_trial_link_check sees it; an instructor''s stays a no-op (hw_update unchanged)');
end $$;

select n, line from v179 order by n;

rollback;
