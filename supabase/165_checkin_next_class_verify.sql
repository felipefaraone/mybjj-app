-- 165_checkin_next_class_verify.sql
--
-- Run AFTER 165, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/165_checkin_next_class_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Wednesday 16 Jul 2031 at the first unit by name (its real Wednesday classes
-- are switched off inside the transaction):
--   16:00 Kids Gi (45)   17:00 one-off Kids No-Gi (30)   18:00 Adults No-Gi
--   18:10 Adults Gi      19:15 All Open Mat
-- _checkin is called with a fixed time (checkin_arrive passes now()).

begin;

create function pg_temp.by(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', case when p is null then '' else json_build_object('sub', p::text, 'role', 'authenticated')::text end, true);
end $f$;
create function pg_temp.at(p text) returns timestamptz language sql immutable as $f$
  select (('2031-07-16 ' || p)::timestamp) at time zone 'Australia/Sydney'
$f$;
-- result, class time, arrival recorded, the row's status / arrival
create function pg_temp.go(p_user uuid, p_unit uuid, p_student uuid, p_at text, p_class jsonb default null, p_write boolean default true)
returns text language plpgsql as $f$
declare r record; v text;
begin
  perform pg_temp.by(p_user);
  select * into r from public._checkin(p_unit, array[p_student], 'qr', p_class, pg_temp.at(p_at), p_write);
  perform pg_temp.by(null);
  v := format('%s %s %s', r.result, coalesce(r.class_time, '-'), coalesce(r.arrival_recorded::text, '-'));
  return v;
end $f$;

do $$
declare
  ua uuid; ty jsonb; ex uuid; comp uuid;
  c1 uuid; c3 uuid; c4 uuid; c5 uuid;
  u_a1 uuid := gen_random_uuid(); u_a2 uuid := gen_random_uuid(); u_a3 uuid := gen_random_uuid();
  u_a4 uuid := gen_random_uuid(); u_a5 uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  u_h1 uuid := gen_random_uuid(); u_par uuid := gen_random_uuid(); u_x uuid := gen_random_uuid();
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; b1 uuid; h1 uuid; k1 uuid; k2 uuid;
  v text; n int; t1 timestamptz;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '16:00', 'jun', 45, 'Kids', true, 'Gi', null, 'zz165k') returning id into c1;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '18:00', 'nogi', 60, 'Adults', true, 'No-Gi', 'All Levels', 'zz165a') returning id into c3;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '18:10', 'alev', 60, 'Adults', true, 'Gi', 'All Levels', 'zz165b') returning id into c5;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '19:15', 'omat', 60, 'All', true, 'Mixed', 'Open Mat', 'zz165o') returning id into c4;
  update public.classes k set active = false
   where k.unit_id = ua and k.day_of_week = 3 and k.id not in (c1, c3, c4, c5);
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience, oneoff_duration_minutes, oneoff_uniform)
                  values ($1, %L::%s, %L::%s, %L::%s, %L, %L::%s, %L) returning id',
                 '2031-07-16', ty ->> 'exception_date', 'oneoff', ty ->> 'kind', '17:00', ty ->> 'oneoff_time', 'Kids',
                 '30', ty ->> 'oneoff_duration_minutes', 'No-Gi')
    into ex using ua;

  insert into auth.users (id, email)
  select x, 'zz165-' || x::text || '@example.invalid' from unnest(array[u_a1, u_a2, u_a3, u_a4, u_a5, u_b, u_h1, u_par, u_x]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x, 'zz165-' || x::text || '@example.invalid', 'Zz165', case when x = u_par then 'parent' else 'student' end, 'approved', ua
    from unnest(array[u_a1, u_a2, u_a3, u_a4, u_a5, u_b, u_h1, u_par, u_x]) x
  on conflict (id) do update set status = excluded.status;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Ann A','Ann','A','adult',ua,true,'ok',u_a1) returning id into a1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Bea B','Bea','B','adult',ua,true,'ok',u_a2) returning id into a2;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Cy C','Cy','C','adult',ua,true,'ok',u_a3) returning id into a3;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Di D','Di','D','adult',ua,true,'ok',u_a4) returning id into a4;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Ed E','Ed','E','adult',ua,true,'ok',u_a5) returning id into a5;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Bo O','Bo','O','adult',ua,true,'ok',u_b) returning id into b1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz165 Hal H','Hal','H','adult',ua,true,'on_hold',u_h1) returning id into h1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz165 Kit K','Kit','K','kids',ua,true,'ok') returning id into k1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, parent_user_id)
    values ('Zz165 Kev K','Kev','K','kids',ua,true,'ok',u_par) returning id into k2;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values (k1, u_par, 'active', 'legacy_sync', 'manage');
  -- Bo said I'm going this morning (himself)
  perform pg_temp.by(u_b);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (b1, c3, '2031-07-16', '18:00', 'nogi', 'going', 1.00, 'nogi', ua);
  perform pg_temp.by(null);

  -- 1. three hours before: checked in (doCI's row, the caller creates it), no arrival
  v := pg_temp.go(u_a1, ua, a1, '15:00');
  select v || ' | ' || string_agg(format('%s/%s/%s/%s/%s/%s/%s', a.status, a.class_id = c3, a.class_legacy_id, a.class_time,
           a.modality, a.created_by = u_a1, coalesce(a.arrived_at::text, 'no arrival')), ',')
    into v from public.attendance a where a.student_id = a1;
  if v <> 'checked_in 18:00 false | going/t/zz165a/18:00/nogi/t/no arrival' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: 3 hours before: %', v;

  -- 1.1 163's bonus still applies to the row once the coach marks it present
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz165 Cup', 'event', '2031-07-01', '2031-07-31', null, 'active', '[]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ua, 'adult', 'zz165 adults');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'self_checkin', 1, true);
  update public.attendance set status = 'present' where student_id = a1;
  select format('points=%s checkin=%s', s.points, s.checkin_points) into v
    from public._competition_scores(comp, null, null) s where s.student_id = a1;
  if v <> 'points=2.00 checkin=1' and v <> 'points=2.00 checkin=1.00' then raise exception 'FAIL 1.1: %', v; end if;
  raise notice 'PASS 1.1: the QR-created row earns 163''s bonus once present (%)', v;

  -- 2. 45 minutes before: checked in with an arrival
  v := pg_temp.go(u_a2, ua, a2, '17:15');
  select v || ' ' || (a.arrived_at = pg_temp.at('17:15')) || ' ' || a.arrived_via into v from public.attendance a where a.student_id = a2;
  if v <> 'checked_in 18:00 true true qr' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: 45 minutes before: % (arrived 17:15 by QR)', v;

  -- 3. 10 minutes after a start: that class
  v := pg_temp.go(u_a3, ua, a3, '18:10');
  if v <> 'checked_in 18:00 true' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: 10 minutes after 18:00 started: %', v;

  -- 4. 20 minutes after a start: the next class
  v := pg_temp.go(u_a4, ua, a4, '18:20');
  if v <> 'checked_in 18:10 true' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: 20 minutes after 18:00 started: % (the next one)', v;

  -- 5. nothing left today
  v := pg_temp.go(u_a5, ua, a5, '19:31') || ' | ' || pg_temp.go(u_par, ua, k1, '19:31', null, false);
  if v <> 'no_class_today - - | no_class_today - -' or exists (select 1 from public.attendance where student_id = a5) then
    raise exception 'FAIL 5: %', v;
  end if;
  raise notice 'PASS 5: after the last class has been on 16 minutes: % (nothing written)', v;

  -- 6. Change: any other class today that fits; one that does not fit, or has gone, refused
  v := pg_temp.go(u_a5, ua, a5, '15:00', jsonb_build_object('class_id', c1), false)
       || ' | ' || pg_temp.go(u_a5, ua, a5, '18:20', jsonb_build_object('class_id', c3), false)
       || ' | ' || pg_temp.go(u_a5, ua, a5, '15:00', jsonb_build_object('class_id', c4));
  if v <> 'invalid_class - - | invalid_class - - | checked_in 19:15 false' then raise exception 'FAIL 6: %', v; end if;
  raise notice 'PASS 6: Change: the kids class refused, a class gone refused, 19:15 chosen: %', v;

  -- 6.1 preview lists every candidate, earliest first, and writes nothing
  perform pg_temp.by(u_a4);
  select string_agg(o ->> 'time', ',') into v
    from public._checkin(ua, array[a4], 'qr', null, pg_temp.at('15:00'), false) x, jsonb_array_elements(x.options) o;
  perform pg_temp.by(null);
  if v <> '18:00,18:10,19:15' then raise exception 'FAIL 6.1: %', v; end if;
  raise notice 'PASS 6.1: an adult''s candidates at 15:00: %', v;

  -- 7. audience: a kid gets the kids class; later the All class
  v := pg_temp.go(u_par, ua, k1, '15:00', null, false) || ' | ' || pg_temp.go(u_par, ua, k1, '18:30', null, false);
  if v <> 'ready 16:00 - | ready 19:15 -' then raise exception 'FAIL 7: %', v; end if;
  raise notice 'PASS 7: audience: %', v;

  -- 8. on hold: refused, nothing written
  v := pg_temp.go(u_h1, ua, h1, '17:30');
  if v <> 'on_hold - -' or exists (select 1 from public.attendance where student_id = h1) then raise exception 'FAIL 8: %', v; end if;
  raise notice 'PASS 8: on hold refused, no row';

  -- 9. a guardian, each kid separately (guardianship; legacy parent): the one-off, with an arrival
  perform pg_temp.by(u_par);
  select string_agg(format('%s %s %s', x.result, x.class_time, x.arrival_recorded), ', ' order by x.student_id = k2) into v
    from public._checkin(ua, array[k1, k2], 'qr', null, pg_temp.at('16:50'), true) x;
  perform pg_temp.by(null);
  select count(*) into n from public.attendance a
   where a.student_id in (k1, k2) and a.class_id is null and a.class_time = '17:00' and a.created_by = u_par and a.arrived_at is not null;
  if v <> 'checked_in 17:00 t, checked_in 17:00 t' or n <> 2 then raise exception 'FAIL 9: % (rows %)', v, n; end if;
  raise notice 'PASS 9: a parent for two kids at 16:50: %', v;

  -- 10. a stranger: not allowed, nothing written
  v := pg_temp.go(u_x, ua, a5, '17:30');
  if v <> 'not_allowed - -' then raise exception 'FAIL 10: %', v; end if;
  raise notice 'PASS 10: someone else''s row: not_allowed';

  -- 11. a row that existed: already; early it adds nothing, then the arrival, never the status
  v := pg_temp.go(u_b, ua, b1, '15:00') || ' | ' || pg_temp.go(u_b, ua, b1, '17:30');
  t1 := (select arrived_at from public.attendance where student_id = b1);
  select v || ' | ' || pg_temp.go(u_b, ua, b1, '17:50') into v;
  select v || ' | ' || a.status || ' ' || (a.arrived_at = pg_temp.at('17:30')) || ' ' || (select count(*) from public.attendance where student_id = b1)
    into v from public.attendance a where a.student_id = b1;
  if v <> 'already 18:00 false | already 18:00 true | already 18:00 false | going true 1' then raise exception 'FAIL 11: %', v; end if;
  raise notice 'PASS 11: Bo''s own row: % (15:00 nothing, 17:30 arrival, 17:50 keeps it; still going, one row)', v;

  -- 11.1 an absent row stays absent
  update public.attendance set status = 'absent', arrived_at = null, arrived_via = null where student_id = b1;
  v := pg_temp.go(u_b, ua, b1, '17:40');
  select v || ' ' || a.status into v from public.attendance a where a.student_id = b1;
  if v <> 'already 18:00 true absent' then raise exception 'FAIL 11.1: %', v; end if;
  raise notice 'PASS 11.1: an absent row stays absent (%)', v;

  -- 12. the TV's window function is untouched by 165
  if (select prosrc from pg_proc where oid = 'public._classes_in_window(uuid, date, time)'::regprocedure) not like '%- 30 <= extract%'
     or position('-- 165' in (select prosrc from pg_proc where oid = 'public._tv_payload(uuid, date, time)'::regprocedure)) > 0 then
    raise exception 'FAIL 12: the TV''s window changed';
  end if;
  raise notice 'PASS 12: _classes_in_window and _tv_payload are 164''s';

  -- 13. grants unchanged
  if has_function_privilege('anon', 'public.checkin_arrive(uuid, uuid[], text, jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.checkin_arrive(uuid, uuid[], text, jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.checkin_preview(uuid, uuid[], jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public._checkin(uuid, uuid[], text, jsonb, timestamptz, boolean)', 'execute') then
    raise exception 'FAIL 13: grants';
  end if;
  raise notice 'PASS 13: authenticated only; _checkin internal';
end $$;

rollback;
