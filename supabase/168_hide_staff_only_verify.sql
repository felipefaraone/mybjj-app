-- 168_hide_staff_only_verify.sql
--
-- Run AFTER 168, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/168_hide_staff_only_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- The first unit by name; a live July 2031 event (adults): Ann 6, Ben 4.
-- People: Ann (member), Gil (guardian of the kid Kit), Sid (staff), Oz (owner),
-- Pat (another member).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- call set_leaderboard_hidden as a user: 'ok' or the error class
create function pg_temp.hide(p_user uuid, p_student uuid, p_hidden boolean) returns text language plpgsql as $f$
declare v text := 'ok';
begin
  perform pg_temp.v_as(p_user);
  begin
    perform public.set_leaderboard_hidden(p_student, p_hidden);
  exception when insufficient_privilege then v := 'refused';
  end;
  execute 'reset role';
  return v;
end $f$;

do $$
declare
  ua uuid; comp uuid;
  u_ann uuid := gen_random_uuid(); u_gil uuid := gen_random_uuid(); u_sid uuid := gen_random_uuid();
  u_oz uuid := gen_random_uuid(); u_pat uuid := gen_random_uuid();
  s_ann uuid; s_ben uuid; s_kit uuid;
  v text;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  insert into auth.users (id, email)
  select x, 'zz168-' || x::text || '@example.invalid' from unnest(array[u_ann, u_gil, u_sid, u_oz, u_pat]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz168-' || x.id::text || '@example.invalid', 'Zz168', x.role, 'approved', ua
    from (values (u_ann, 'student'), (u_gil, 'parent'), (u_sid, 'instructor'), (u_oz, 'student'), (u_pat, 'student')) x(id, role)
  on conflict (id) do update set role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_oz) on conflict do nothing;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz168 Ann A','Ann','A','adult',ua,true,'ok',u_ann) returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz168 Ben B','Ben','B','adult',ua,true,'ok') returning id into s_ben;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, parent_user_id)
    values ('Zz168 Kit K','Kit','K','kids',ua,true,'ok',u_gil) returning id into s_kit;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values (s_kit, u_gil, 'active', 'legacy_sync', 'manage');

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz168 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ua, 'adult', 'Zz168 adults');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values (comp, 'class_attended', 1, true);
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, date '2031-07-01' + g, '07:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_ann, 6), (s_ben, 4)) x(sid, k), generate_series(0, 5) g where g < x.k;

  -- 1. a member hiding themselves is refused, and nothing changes
  v := pg_temp.hide(u_ann, s_ann, true);
  if v <> 'refused' or (select leaderboard_hidden from public.students where id = s_ann) then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: a member hiding themselves: %', v;

  -- 2. a guardian hiding a kid is refused
  v := pg_temp.hide(u_gil, s_kit, true);
  if v <> 'refused' or (select leaderboard_hidden from public.students where id = s_kit) then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: a guardian hiding a kid: %', v;

  -- 3. staff and admin hide and unhide anyone
  -- one statement per step: a read in the same statement would not see the change
  v := pg_temp.hide(u_sid, s_ben, true);
  v := v || '/' || (select leaderboard_hidden from public.students where id = s_ben)::text;
  v := v || ' ' || pg_temp.hide(u_sid, s_ben, false);
  v := v || '/' || (select leaderboard_hidden from public.students where id = s_ben)::text;
  v := v || ' ' || pg_temp.hide(u_oz, s_kit, true);
  v := v || '/' || (select leaderboard_hidden from public.students where id = s_kit)::text;
  v := v || ' ' || pg_temp.hide(u_oz, s_kit, false);
  v := v || '/' || (select leaderboard_hidden from public.students where id = s_kit)::text;
  if v <> 'ok/true ok/false ok/true ok/false' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: staff hide / unhide Ben, the owner hide / unhide Kit: %', v;

  -- 4. 166 is unchanged for a staff-hidden member: Anonymous to another member, real to
  --    the member themselves and to staff
  perform pg_temp.hide(u_sid, s_ann, true);
  perform pg_temp.v_as(u_pat);
  select string_agg(format('%s:%s:%s', s.rank, s.display_name, s.is_anonymous::text), ' | ' order by s.rank) into v
    from public.competition_standings(comp, null, null) s where s.points > 0;
  execute 'reset role';
  perform pg_temp.v_as(u_ann);
  select v || ' || self ' || string_agg(format('%s:%s', s.rank, s.display_name), ' | ' order by s.rank) into v
    from public.competition_standings(comp, null, null) s where s.points > 0;
  execute 'reset role';
  perform pg_temp.v_as(u_sid);
  select v || ' || staff ' || string_agg(format('%s:%s', s.rank, s.display_name), ' | ' order by s.rank) into v
    from public.competition_standings(comp, null, null) s where s.points > 0;
  execute 'reset role';
  if v <> '1:Anonymous:true | 2:Ben B:false || self 1:Ann A | 2:Ben B || staff 1:Ann A | 2:Ben B' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: staff-hidden Ann: %', v;

  -- 5. signature and grants unchanged
  if not has_function_privilege('authenticated', 'public.set_leaderboard_hidden(uuid, boolean)', 'execute')
     or has_function_privilege('anon', 'public.set_leaderboard_hidden(uuid, boolean)', 'execute') then
    raise exception 'FAIL 5: grants';
  end if;
  raise notice 'PASS 5: set_leaderboard_hidden(uuid, boolean): authenticated only, as before';
end $$;

rollback;
