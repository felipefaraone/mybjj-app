-- 171_open_mat_quarter_verify.sql
--
-- Run AFTER 171, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/171_open_mat_quarter_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Everything is dated March 2001 (no real attendance then) on the first unit by
-- name. Classes: Zz171 Open Mat (level 'Open Mat'), Zz171 Gi (All Levels),
-- Zz171 Late (All Levels until test 8 makes it an open mat). One-offs on 9 Mar:
-- 14:00 Open Mat, 15:00 All Levels, 16:00 All Levels (an open mat from test 8).
-- People: Ann (adult, a login: the self check-in bonus), Bo (values), Cy (day
-- max), Dee (backfill); Sid is staff. Event Zz171 Cup: class_attended 1,
-- self_checkin 1.

begin;

-- the user the next write is made by (163's helper)
create function pg_temp.by(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', case when p is null then '' else json_build_object('sub', p::text, 'role', 'authenticated')::text end, true);
end $f$;
create function pg_temp.cv(p uuid) returns numeric language sql as $f$
  select class_value from public.attendance where id = p
$f$;
-- a one-off class_exceptions row (its column types read off the table, as 157 / 158 do)
create function pg_temp.oneoff(p_unit uuid, p_date text, p_time text, p_level text) returns text language plpgsql as $f$
declare ty jsonb; v text;
begin
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience,
                    oneoff_duration_minutes, oneoff_uniform, oneoff_level)
                  values ($1::text::%s, %L::%s, %L::%s, %L::%s, %L::%s, %L::%s, %L::%s, %L::%s) returning id::text',
                 ty ->> 'unit_id', p_date, ty ->> 'exception_date', 'oneoff', ty ->> 'kind', p_time, ty ->> 'oneoff_time',
                 'Adults', ty ->> 'oneoff_audience', '60', ty ->> 'oneoff_duration_minutes', 'Mixed', ty ->> 'oneoff_uniform',
                 p_level, ty ->> 'oneoff_level')
    into v using p_unit;
  return v;
end $f$;

do $$
declare
  ua uuid; comp uuid; c_om uuid; c_gi uuid; c_late uuid;
  x_om text; x_gi text; x_late text; l_om text; l_gi text; l_late text;
  u_ann uuid := gen_random_uuid(); u_sid uuid := gen_random_uuid();
  s_ann uuid; s_bo uuid; s_cy uuid; s_dee uuid;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; a6 uuid; a7 uuid; a8 uuid; d1 uuid; d2 uuid;
  v text; n numeric; k int;
begin
  -- 0. structure
  if to_regprocedure('public._is_open_mat(uuid, text)') is null
     or to_regprocedure('public._attendance_open_mat_backfill()') is null then
    raise exception 'FAIL 0: a 171 function is missing';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.attendance'::regclass
                    and t.tgname = 'trg_attendance_open_mat_value' and t.tgenabled <> 'D'
                    and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 and t.tgtype & 16 = 16) then
    raise exception 'FAIL 0: trg_attendance_open_mat_value is not an enabled BEFORE INSERT OR UPDATE trigger';
  end if;
  if has_function_privilege('authenticated', 'public._is_open_mat(uuid, text)', 'execute')
     or has_function_privilege('authenticated', 'public._attendance_open_mat_value()', 'execute')
     or has_function_privilege('authenticated', 'public._attendance_open_mat_backfill()', 'execute') then
    raise exception 'FAIL 0: a 171 function is callable by a client';
  end if;
  if not exists (select 1 from pg_class where oid = 'public._bak_attendance_openmat_20261025'::regclass and relrowsecurity) then
    raise exception 'FAIL 0: backup table missing or without RLS';
  end if;
  select string_agg(t.tgname, ', ' order by t.tgname) into v
    from pg_trigger t where t.tgrelid = 'public.attendance'::regclass and not t.tgisinternal;
  raise notice 'PASS 0: functions internal, trigger BEFORE INSERT OR UPDATE, backup has RLS; attendance triggers: %', v;

  -- 0.1 the backfill already ran: no present open-mat row has another value
  select count(*) into k from public.attendance a
   where a.status = 'present' and a.class_value is distinct from 0.25 and public._is_open_mat(a.class_id, a.class_legacy_id);
  if k <> 0 then raise exception 'FAIL 0.1: % present open-mat row(s) are not 0.25', k; end if;
  raise notice 'PASS 0.1: every present open-mat row is 0.25';

  -- setup
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 6, '05:01', 'omat', 60, 'All', true, 'Mixed', 'Open Mat', 'zz171o') returning id into c_om;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 6, '05:02', 'alev', 60, 'Adults', true, 'Gi', 'All Levels', 'zz171g') returning id into c_gi;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 6, '05:03', 'alev', 60, 'Adults', true, 'Gi', 'All Levels', 'zz171l') returning id into c_late;
  x_om := pg_temp.oneoff(ua, '2001-03-09', '14:00', 'Open Mat');
  x_gi := pg_temp.oneoff(ua, '2001-03-09', '15:00', 'All Levels');
  x_late := pg_temp.oneoff(ua, '2001-03-09', '16:00', 'All Levels');
  l_om := '2001-03-09_14:00_oneoff_' || x_om;
  l_gi := '2001-03-09_15:00_oneoff_' || x_gi;
  l_late := '2001-03-09_16:00_oneoff_' || x_late;

  insert into auth.users (id, email)
  select x, 'zz171-' || x::text || '@example.invalid' from unnest(array[u_ann, u_sid]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz171-' || x.id::text || '@example.invalid', x.nm, x.role, 'approved', ua
    from (values (u_ann, 'Zz171 Ann', 'student'), (u_sid, 'Zz171 Sid', 'instructor')) x(id, nm, role)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz171 Ann A', 'Ann', 'A', 'adult', ua, true, 'ok', u_ann) returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz171 Bo B', 'Bo', 'B', 'adult', ua, true, 'ok') returning id into s_bo;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz171 Cy C', 'Cy', 'C', 'adult', ua, true, 'ok') returning id into s_cy;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz171 Dee D', 'Dee', 'D', 'adult', ua, true, 'ok') returning id into s_dee;

  -- 1. _is_open_mat
  select format('om=%s gi=%s oneoff_om=%s oneoff_gi=%s none=%s plain_legacy=%s bad_tail=%s',
                public._is_open_mat(c_om, null), public._is_open_mat(c_gi, 'zz171g'),
                public._is_open_mat(null, l_om), public._is_open_mat(null, l_gi),
                public._is_open_mat(null, null), public._is_open_mat(null, '2001-03-09_14:00_zz171o'),
                public._is_open_mat(null, '2001-03-09_14:00_oneoff_not-a-uuid')) into v;
  if v <> 'om=t gi=f oneoff_om=t oneoff_gi=f none=f plain_legacy=f bad_tail=f' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: _is_open_mat %', v;

  -- 2. recurring open mat: present is 0.25 whatever is sent, on insert and update
  perform pg_temp.by(u_sid);
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, c_om, 'zz171o', '2001-03-03', '05:01', 'omat', 'present', 1.00, ua) returning id into a1;
  v := pg_temp.cv(a1)::text;
  update public.attendance set class_value = 0.50 where id = a1;
  v := v || ' ' || pg_temp.cv(a1)::text;
  update public.attendance set status = 'present', class_value = 1.00, confirmed_at = now() where id = a1;
  v := v || ' ' || pg_temp.cv(a1)::text;
  if v <> '0.25 0.25 0.25' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: recurring open mat present: insert 1.00, update 0.50, update 1.00 all give 0.25 (%)', v;

  -- 3. one-off open mat (class_id null, the legacy id names the exception)
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, null, l_om, '2001-03-09', '14:00', null, 'present', 1.00, ua) returning id into a2;
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, null, l_gi, '2001-03-09', '15:00', null, 'present', 0.50, ua) returning id into a3;
  v := pg_temp.cv(a2) || ' ' || pg_temp.cv(a3);
  if v <> '0.25 0.50' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: one-off open mat present gives 0.25; a normal one-off keeps 0.50 (%)', v;

  -- 4. a normal class keeps the value sent
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, c_gi, 'zz171g', '2001-03-03', '05:02', 'alev', 'present', 0.50, ua) returning id into a4;
  v := pg_temp.cv(a4)::text;
  update public.attendance set class_value = 0.00 where id = a4;
  v := v || ' ' || pg_temp.cv(a4)::text;
  update public.attendance set class_value = 1.00 where id = a4;
  v := v || ' ' || pg_temp.cv(a4)::text;
  if v <> '0.50 0.00 1.00' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: a normal class keeps the coach''s tier (%)', v;

  -- 5. going and absent rows are not touched; going -> present becomes 0.25
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, c_om, 'zz171o', '2001-03-10', '05:01', 'omat', 'going', 1.00, ua) returning id into a5;
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_bo, c_om, 'zz171o', '2001-03-17', '05:01', 'omat', 'absent', 0.50, ua) returning id into a6;
  v := pg_temp.cv(a5) || ' ' || pg_temp.cv(a6);
  update public.attendance set confirmed_at = now() where id in (a5, a6);
  v := v || ' ' || pg_temp.cv(a5) || ' ' || pg_temp.cv(a6);
  update public.attendance set status = 'present' where id = a5;
  v := v || ' ' || pg_temp.cv(a5);
  if v <> '1.00 0.50 1.00 0.50 0.25' then raise exception 'FAIL 5: %', v; end if;
  raise notice 'PASS 5: going and absent keep their value on insert and update; going -> present gives 0.25 (%)', v;

  -- 6. the self check-in bonus stays 1 on an open mat
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz171 Cup', 'event', '2001-03-01', '2001-03-31', '2001-04-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label)
  select comp, ua, x.aud, 'Zz171 ' || x.aud from (values ('adult'), ('kids')) x(aud);
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'self_checkin', 1, true);
  perform pg_temp.by(u_ann);     -- Ann taps I'm going on the open mat
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_ann, c_om, 'zz171o', '2001-03-24', '05:01', 'omat', 'going', 1.00, ua) returning id into a7;
  perform pg_temp.by(u_sid);     -- the coach marks her present at 1.00
  update public.attendance set status = 'present', class_value = 1.00, confirmed_at = now() where id = a7;
  perform pg_temp.by(null);
  select format('value=%s classes=%s bonus=%s', pg_temp.cv(a7), s.class_points,
                s.points - s.class_points - s.award_points - s.referral_points) into v
    from public._competition_scores(comp, null, null) s where s.student_id = s_ann;
  if v is distinct from 'value=0.25 classes=0.25 bonus=1.00' then raise exception 'FAIL 6: %', coalesce(v, 'Ann not scored'); end if;
  raise notice 'PASS 6: an own open-mat check in counts 0.25 and keeps the self check-in bonus of 1 (%)', v;

  -- 7. progression: the day counts its highest class, so an open mat on the
  --    same day as a 1.00 class does not lower it; an open mat alone adds 0.25
  perform pg_temp.by(u_sid);
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id) values
    (s_cy, c_gi, 'zz171g', '2001-03-20', '05:02', 'alev', 'present', 1.00, ua),
    (s_cy, c_om, 'zz171o', '2001-03-20', '05:01', 'omat', 'present', 1.00, ua),
    (s_cy, c_om, 'zz171o', '2001-03-27', '05:01', 'omat', 'present', 1.00, ua);
  select format('grade=%s total=%s', s.grade - coalesce(s.baseline_grade, 0), s.total - coalesce(s.baseline_total, 0)) into v
    from public.students s where s.id = s_cy;
  if v <> 'grade=1.25 total=1.50' then raise exception 'FAIL 7: %', v; end if;
  raise notice 'PASS 7: day max: 1.00 class + open mat the same day = 1.00, open mat alone = 0.25 (%)', v;

  -- 8. the backfill: rows from before 171 are made here by turning classes into
  --    open mats AFTER their rows exist (no trigger is disabled, no table lock)
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_dee, c_late, 'zz171l', '2001-03-03', '05:03', 'alev', 'present', 1.00, ua) returning id into d1;
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_dee, null, l_late, '2001-03-09', '16:00', null, 'present', 0.50, ua) returning id into d2;
  insert into public.attendance (student_id, class_id, class_legacy_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_dee, c_late, 'zz171l', '2001-03-10', '05:03', 'alev', 'going', 1.00, ua) returning id into a8;
  perform pg_temp.by(null);
  update public.classes set level = 'Open Mat' where id = c_late;
  execute 'update public.class_exceptions set oneoff_level = $1 where id::text = $2' using 'Open Mat', x_late;
  select s.total - coalesce(s.baseline_total, 0) into n from public.students s where s.id = s_dee;
  k := public._attendance_open_mat_backfill();
  -- (k counts every row it changed; any other is a class turned into an open mat
  --  after 171 ran, so only "at least Dee's two" is asserted)
  select format('changed>=2:%s before=%s values=%s/%s/%s total=%s', k >= 2, n, pg_temp.cv(d1), pg_temp.cv(d2), pg_temp.cv(a8),
                (select s.total - coalesce(s.baseline_total, 0) from public.students s where s.id = s_dee)) into v;
  if v <> 'changed>=2:t before=1.50 values=0.25/0.25/1.00 total=0.50' then raise exception 'FAIL 8: %', v; end if;
  raise notice 'PASS 8: backfill sets present open-mat rows (recurring and one-off) to 0.25, leaves going, recomputes (%)', v;

  -- 9. after the backfill no present open-mat row has another value
  select count(*) into k from public.attendance a
   where a.status = 'present' and a.class_value is distinct from 0.25 and public._is_open_mat(a.class_id, a.class_legacy_id);
  if k <> 0 then raise exception 'FAIL 9: % present open-mat row(s) are not 0.25', k; end if;
  raise notice 'PASS 9: no present open-mat row with a value other than 0.25';
end $$;

rollback;
