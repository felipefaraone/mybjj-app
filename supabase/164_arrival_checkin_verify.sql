-- 164_arrival_checkin_verify.sql
--
-- Run AFTER 164, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/164_arrival_checkin_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Wednesday 16 Jul 2031 at the first unit by name (no real classes then: the
-- day's classes are these, the real timetable never interferes because the
-- verify reads only its own rows):
--   16:00 Kids Gi (45)   17:00 one-off Kids No-Gi (30)   18:00 Adults No-Gi
--   18:10 Adults Gi      19:15 All Open Mat
-- The window: 30 minutes before a start until 15 after (Sydney). _checkin is
-- called with a fixed time (checkin_arrive passes now()).
-- Since 165 the check in takes the next class today (no 30/15 window; that stays
-- the TV's) and returns checked_in / already; the expectations below that 165
-- changes are marked "165".

begin;

create function pg_temp.by(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', case when p is null then '' else json_build_object('sub', p::text, 'role', 'authenticated')::text end, true);
end $f$;
create function pg_temp.at(p text) returns timestamptz language sql immutable as $f$
  select (('2031-07-16 ' || p)::timestamp) at time zone 'Australia/Sydney'
$f$;

do $$
declare
  ua uuid; scr uuid; ty jsonb; ex uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid;
  u_a1 uuid := gen_random_uuid(); u_a2 uuid := gen_random_uuid(); u_a3 uuid := gen_random_uuid();
  u_a4 uuid := gen_random_uuid(); u_a5 uuid := gen_random_uuid(); u_a6 uuid := gen_random_uuid();
  u_h1 uuid := gen_random_uuid(); u_par uuid := gen_random_uuid(); u_x uuid := gen_random_uuid();
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; a6 uuid; h1 uuid; k1 uuid; k2 uuid;
  r record; v text; n int; m int; t1 timestamptz; p jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '16:00', 'jun', 45, 'Kids', true, 'Gi', null, 'zz164k') returning id into c1;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '18:00', 'nogi', 60, 'Adults', true, 'No-Gi', 'All Levels', 'zz164a') returning id into c3;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '18:10', 'alev', 60, 'Adults', true, 'Gi', 'All Levels', 'zz164b') returning id into c5;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '19:15', 'omat', 60, 'All', true, 'Mixed', 'Open Mat', 'zz164o') returning id into c4;
  -- the real timetable of that Wednesday is closed out: only these classes count
  update public.classes k set active = false
   where k.unit_id = ua and k.day_of_week = 3 and k.id not in (c1, c3, c4, c5);
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience, oneoff_duration_minutes, oneoff_uniform)
                  values ($1, %L::%s, %L::%s, %L::%s, %L, %L::%s, %L) returning id',
                 '2031-07-16', ty ->> 'exception_date', 'oneoff', ty ->> 'kind', '17:00', ty ->> 'oneoff_time', 'Kids',
                 '30', ty ->> 'oneoff_duration_minutes', 'No-Gi')
    into ex using ua;
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz164 tv', ua, encode(sha256('zz164'::bytea), 'hex'), true) returning id into scr;

  insert into auth.users (id, email)
  select x, 'zz164-' || x::text || '@example.invalid' from unnest(array[u_a1, u_a2, u_a3, u_a4, u_a5, u_a6, u_h1, u_par, u_x]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x, 'zz164-' || x::text || '@example.invalid', 'Zz164', case when x = u_par then 'parent' else 'student' end, 'approved', ua
    from unnest(array[u_a1, u_a2, u_a3, u_a4, u_a5, u_a6, u_h1, u_par, u_x]) x
  on conflict (id) do update set status = excluded.status;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Ann A','Ann','A','adult',ua,true,'ok',u_a1,'blue') returning id into a1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Bo B','Bo','B','adult',ua,true,'ok',u_a2,'white') returning id into a2;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Cy C','Cy','C','adult',ua,true,'ok',u_a3,'purple') returning id into a3;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Di D','Di','D','adult',ua,true,'ok',u_a4,'white') returning id into a4;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Ed E','Ed','E','adult',ua,true,'ok',u_a5,'white') returning id into a5;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt, leaderboard_hidden)
    values ('Zz164 Hid H','Hid','H','adult',ua,true,'ok',u_a6,'blue',true) returning id into a6;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id, belt)
    values ('Zz164 Hal H','Hal','H','adult',ua,true,'on_hold',u_h1,'white') returning id into h1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz164 Kit K','Kit','K','kids',ua,true,'ok','grey') returning id into k1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, parent_user_id)
    values ('Zz164 Kev K','Kev','K','kids',ua,true,'ok','yellow',u_par) returning id into k2;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values (k1, u_par, 'active', 'legacy_sync', 'manage');
  -- Bo said going this morning (himself); Cy was marked absent by staff
  perform pg_temp.by(u_a2);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (a2, c3, '2031-07-16', '18:00', 'nogi', 'going', 1.00, 'nogi', ua);
  perform pg_temp.by(null);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (a3, c3, '2031-07-16', '18:00', 'nogi', 'absent', 1.00, 'nogi', ua);

  -- 1. self, no row yet: the row doCI writes, going, created by the caller; arrived by QR
  perform pg_temp.by(u_a1);
  select * into r from public._checkin(ua, array[a1], 'qr', null, pg_temp.at('17:40'), true);
  perform pg_temp.by(null);
  select format('%s %s %s | %s', r.result, r.class_time, r.class_label, string_agg(format('%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s',
           a.status, a.class_id = c3, a.class_legacy_id, a.class_date, a.class_time, a.class_type, a.modality, a.gi,
           a.unit_id = ua, a.class_value = 1, a.created_by = u_a1, a.arrived_via), ','))
    into v from public.attendance a where a.student_id = a1;
  if v <> 'checked_in 18:00 No-Gi · All Levels | going/t/zz164a/2031-07-16/18:00/nogi/nogi/f/t/t/t/qr'   -- 165: checked_in
     or r.arrived_at <> pg_temp.at('17:40') then
    raise exception 'FAIL 1: % (arrived %)', v, r.arrived_at;
  end if;
  if not public._attendance_is_self((select created_by from public.attendance where student_id = a1), a1) then
    raise exception 'FAIL 1: 163 would not see a self check in';
  end if;
  raise notice 'PASS 1: self, no row: % (163''s bonus applies once present)', v;

  -- 2. a parent for two kids (guardianship; legacy parent_user_id): the one-off kids class
  perform pg_temp.by(u_par);
  select string_agg(format('%s %s %s', x.result, x.class_time, x.class_legacy_id = '2031-07-16_17:00_oneoff_' || ex::text), ', ' order by x.student_id = k2)
    into v from public._checkin(ua, array[k1, k2], 'qr', null, pg_temp.at('16:50'), true) x;
  perform pg_temp.by(null);
  select count(*) into n from public.attendance a
   where a.student_id in (k1, k2) and a.class_id is null and a.class_time = '17:00' and a.status = 'going'
     and a.created_by = u_par and a.class_type is null and a.modality = 'nogi' and a.gi = false and a.arrived_via = 'qr';
  if v <> 'checked_in 17:00 t, checked_in 17:00 t' or n <> 2 then raise exception 'FAIL 2: % (rows %)', v, n; end if;   -- 165: checked_in
  raise notice 'PASS 2: a parent checks in each kid separately (one-off, guardian as creator): %', v;

  -- 3. a stranger: not allowed, nothing written
  select count(*) into m from public.attendance where student_id = a4;
  perform pg_temp.by(u_x);
  select string_agg(x.result, ',') into v from public._checkin(ua, array[a4, gen_random_uuid()], 'qr', null, pg_temp.at('17:40'), true) x;
  perform pg_temp.by(null);
  if v <> 'not_allowed,not_allowed' or (select count(*) from public.attendance where student_id = a4) <> m then
    raise exception 'FAIL 3: %', v;
  end if;
  raise notice 'PASS 3: someone else''s row and an unknown id: % (nothing written)', v;

  -- 4. on hold: refused, no row
  perform pg_temp.by(u_h1);
  select x.result into v from public._checkin(ua, array[h1], 'app', null, pg_temp.at('17:40'), true) x;
  perform pg_temp.by(null);
  if v <> 'on_hold' or exists (select 1 from public.attendance where student_id = h1) then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: on hold refused, no row written';

  -- 5. outside the window: no_class with when the next fitting class opens
  perform pg_temp.by(u_a4);
  select format('%s %s %s', x.result, x.class_time, x.opens_at) into v from public._checkin(ua, array[a4], 'qr', null, pg_temp.at('19:31'), true) x;   -- 165: after the last class
  perform pg_temp.by(u_par);
  select v || ' | ' || format('%s %s %s', x.result, x.class_time, x.opens_at) into v
    from public._checkin(ua, array[k1], 'qr', null, pg_temp.at('19:31'), true) x;
  perform pg_temp.by(null);
  if v <> 'no_class_today   | no_class_today  ' or exists (select 1 from public.attendance where student_id = a4) then   -- 165
    raise exception 'FAIL 5: %', v;
  end if;
  raise notice 'PASS 5: no class left today: % (adult and kid at 19:31)', v;

  -- 6. an existing going row keeps its status and only gains arrived_at
  perform pg_temp.by(u_a2);
  select * into r from public._checkin(ua, array[a2], 'app', null, pg_temp.at('17:45'), true);
  perform pg_temp.by(null);
  select format('%s %s %s %s', r.result, a.status, a.created_by = u_a2, a.arrived_via) into v
    from public.attendance a where a.student_id = a2;
  if v <> 'already going t app' or (select count(*) from public.attendance where student_id = a2) <> 1 then raise exception 'FAIL 6: %', v; end if;   -- 165: the row existed
  raise notice 'PASS 6: an existing going row: % (no second row)', v;

  -- 7. a second scan keeps the first arrival
  t1 := (select arrived_at from public.attendance where student_id = a2);
  perform pg_temp.by(u_a2);
  select x.result into v from public._checkin(ua, array[a2], 'qr', null, pg_temp.at('17:58'), true) x;
  perform pg_temp.by(null);
  if v <> 'already' or (select arrived_at from public.attendance where student_id = a2) <> t1
     or (select arrived_via from public.attendance where student_id = a2) <> 'app' then
    raise exception 'FAIL 7: %', v;
  end if;
  raise notice 'PASS 7: a second scan: already, the first time and way kept (17:45, app)';

  -- 8. an absent row stays absent
  perform pg_temp.by(u_a3);
  select x.result into v from public._checkin(ua, array[a3], 'qr', null, pg_temp.at('17:50'), true) x;
  perform pg_temp.by(null);
  select v || ' ' || a.status into v from public.attendance a where a.student_id = a3;
  if v <> 'already absent' then raise exception 'FAIL 8: %', v; end if;   -- 165: the row existed
  raise notice 'PASS 8: an absent row stays absent (%)', v;

  -- 9. the class: nearest by default; a chosen class in the window; one outside refused
  perform pg_temp.by(u_a5);
  select format('%s %s', x.result, x.class_time) into v from public._checkin(ua, array[a5], 'qr', null, pg_temp.at('17:50'), false) x;
  select v || ' | ' || format('%s %s', x.result, x.class_time) into v
    from public._checkin(ua, array[a5], 'qr', jsonb_build_object('class_id', c3), pg_temp.at('18:20'), true) x;   -- 165: a class gone
  select v || ' | ' || format('%s %s', x.result, x.class_time) into v
    from public._checkin(ua, array[a5], 'qr', jsonb_build_object('class_id', c5), pg_temp.at('17:50'), true) x;
  perform pg_temp.by(null);
  if v <> 'ready 18:00 | invalid_class  | checked_in 18:10'   -- 165
     or (select count(*) from public.attendance where student_id = a5) <> 1
     or not exists (select 1 from public.attendance where student_id = a5 and class_id = c5) then
    raise exception 'FAIL 9: %', v;
  end if;
  raise notice 'PASS 9: the earliest is 18:00; 18:00 at 18:20 (gone) refused; 18:10 chosen: %', v;

  -- 9.1 kids vs adults: at 18:50 the All class fits both; at 16:50 the adult has nothing
  perform pg_temp.by(u_par);
  select format('%s %s', x.result, x.class_time) into v from public._checkin(ua, array[k1], 'qr', null, pg_temp.at('18:50'), false) x;
  perform pg_temp.by(u_a4);
  select v || ' | ' || format('%s %s', x.result, x.class_time) into v from public._checkin(ua, array[a4], 'qr', null, pg_temp.at('18:50'), false) x;
  select v || ' | ' || format('%s %s', x.result, x.opens_at) into v from public._checkin(ua, array[a4], 'qr', null, pg_temp.at('16:50'), false) x;
  perform pg_temp.by(null);
  if v <> 'ready 19:15 | ready 19:15 | ready ' then raise exception 'FAIL 9.1: %', v; end if;   -- 165: at 16:50 the adult gets 18:00
  raise notice 'PASS 9.1: audience: %', v;

  -- 9.2 preview writes nothing and lists the fitting window classes
  perform pg_temp.by(u_a4);
  select format('%s %s %s', x.result, x.class_time, (select string_agg(o ->> 'time', ',') from jsonb_array_elements(x.options) o)) into v
    from public._checkin(ua, array[a4], 'qr', null, pg_temp.at('17:50'), false) x;
  perform pg_temp.by(null);
  if v <> 'ready 18:00 18:00,18:10,19:15' or exists (select 1 from public.attendance where student_id = a4) then raise exception 'FAIL 9.2: %', v; end if;   -- 165: every class left today
  raise notice 'PASS 9.2: preview: % (nothing written)', v;

  -- 10. the TV: Up next counts an arrival as here; arrivals lists them, never the hidden or the absent
  perform pg_temp.by(u_a6);
  perform public._checkin(ua, array[a6], 'qr', null, pg_temp.at('17:52'), true);
  perform pg_temp.by(null);
  p := public._tv_payload(scr, '2031-07-16', '17:55');
  select format('here=%s way=%s', b ->> 'here', b ->> 'on_the_way') into v
    from jsonb_array_elements(p -> 'up_next') b where b ->> 'audience' = 'Adults';
  -- the adults' window classes at 17:55 start at 18:10 (the latest start): Ed arrived
  if v <> 'here=1 way=0' then raise exception 'FAIL 10: up_next %', p -> 'up_next'; end if;
  select string_agg(e ->> 'name', ',' order by e ->> 'name') into v from jsonb_array_elements(p -> 'arrivals') e;
  if v <> 'Ann A,Bo B,Ed E' then raise exception 'FAIL 10: arrivals % (%)', v, p -> 'arrivals'; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'arrivals') e
              where not (e ? 'arrived_at' and e ? 'audience' and e ? 'minor' and e ? 'belt')) then
    raise exception 'FAIL 10: arrival fields %', p -> 'arrivals';
  end if;
  raise notice 'PASS 10: TV Up next counts the arrival as here; arrivals %, no hidden member, no absent row', v;

  -- 10.1 before 164 a going row was on the way: an arrival is what moves it
  update public.attendance set arrived_at = null, arrived_via = null where student_id = a5;
  p := public._tv_payload(scr, '2031-07-16', '17:55');
  select format('here=%s way=%s', b ->> 'here', b ->> 'on_the_way') into v
    from jsonb_array_elements(p -> 'up_next') b where b ->> 'audience' = 'Adults';
  if v <> 'here=0 way=1' then raise exception 'FAIL 10.1: %', v; end if;
  raise notice 'PASS 10.1: the same going row without an arrival is on the way (%)', v;

  -- 11. grants, and the wrappers' guards
  if has_function_privilege('anon', 'public.checkin_arrive(uuid, uuid[], text, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.checkin_preview(uuid, uuid[], jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.checkin_arrive(uuid, uuid[], text, jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.checkin_preview(uuid, uuid[], jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public._checkin(uuid, uuid[], text, jsonb, timestamptz, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public._classes_on_day(uuid, date)', 'execute')
     or has_function_privilege('authenticated', 'public._classes_in_window(uuid, date, time)', 'execute') then
    raise exception 'FAIL 11: grants';
  end if;
  perform pg_temp.by(u_a1);
  begin
    perform public.checkin_arrive(ua, array[a1], 'sms');
    v := 'accepted';
  exception when invalid_parameter_value then v := 'refused';
  end;
  begin
    perform public.checkin_arrive(gen_random_uuid(), array[a1], 'qr');
    v := v || ' accepted';
  exception when invalid_parameter_value then v := v || ' refused';
  end;
  perform pg_temp.by(null);
  begin
    perform public.checkin_arrive(ua, array[a1], 'qr');
    v := v || ' accepted';
  exception when insufficient_privilege then v := v || ' refused';
  end;
  if v <> 'refused refused refused' then raise exception 'FAIL 11: %', v; end if;
  raise notice 'PASS 11: authenticated only, internals hidden; a bad way, an unknown unit and no sign in are refused';
end $$;

rollback;
