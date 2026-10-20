-- 166_hidden_as_anonymous_verify.sql
--
-- Run AFTER 166, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/166_hidden_as_anonymous_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- The first unit by name. A live event in July 2031 (adults and kids) and an
-- ended one in March 2001 that the owner publishes:
--   adults: Alison (hidden) 9, David 7, Eve 5        kids: Kit (hidden) 4, Lou 3
--   March 2001: Alison (hidden) 1st, David 2nd, Eve 3rd, Hank (hidden) 4th (no prize)
-- Viewers: David, Alison herself, staff, Kit's guardian, Lou's guardian, a member
-- with no kids. Wednesday 16 Jul 2031 has one class, 18:00 Adults (the unit's
-- other Wednesday classes are switched off inside the transaction).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- one viewer's board: rank:name:anon per row, by audience then rank
create function pg_temp.board(p_user uuid, p_comp uuid, p_aud text) returns text language plpgsql as $f$
declare v text;
begin
  perform pg_temp.v_as(p_user);
  -- the people on the board (points > 0, as the app's board shows them)
  select string_agg(format('%s:%s:%s', s.rank, s.display_name, s.is_anonymous::text), ' | ' order by s.rank, s.display_name) into v
    from public.competition_standings(p_comp, null, null) s where s.audience = p_aud and s.points > 0;
  execute 'reset role';
  return coalesce(v, '-');
end $f$;

do $$
declare
  ua uuid; comp uuid; old uuid; scr uuid; cls uuid;
  u_adm uuid := gen_random_uuid(); u_stf uuid := gen_random_uuid(); u_ali uuid := gen_random_uuid();
  u_dav uuid := gen_random_uuid(); u_eve uuid := gen_random_uuid(); u_hank uuid := gen_random_uuid();
  u_pk uuid := gen_random_uuid(); u_pl uuid := gen_random_uuid(); u_peer uuid := gen_random_uuid();
  s_ali uuid; s_dav uuid; s_eve uuid; s_hank uuid; s_kit uuid; s_lou uuid; s_peer uuid;
  v text; r record; p jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz166 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]') returning id into comp;
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz166 Old', 'event', '2001-03-01', '2001-03-31', '2001-04-01', 'active',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]') returning id into old;
  insert into public.competition_divisions (competition_id, unit_id, audience, label)
  select c, ua, x.a, 'Zz166 ' || x.a from unnest(array[comp, old]) c, (values ('adult'), ('kids')) x(a);
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (old, 'class_attended', 1, true);

  insert into auth.users (id, email)
  select x, 'zz166-' || x::text || '@example.invalid' from unnest(array[u_adm, u_stf, u_ali, u_dav, u_eve, u_hank, u_pk, u_pl, u_peer]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz166-' || x.id::text || '@example.invalid', 'Zz166', x.role, 'approved', ua
    from (values (u_adm, 'student'), (u_stf, 'instructor'), (u_ali, 'student'), (u_dav, 'student'), (u_eve, 'student'),
                 (u_hank, 'student'), (u_pk, 'parent'), (u_pl, 'parent'), (u_peer, 'student')) x(id, role)
  on conflict (id) do update set role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_adm) on conflict do nothing;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, leaderboard_hidden, photo_url)
    values ('Zz166 Alison Lee','Alison','Lee','adult',ua,true,'ok','purple',2,u_ali,true,'zz166/ali.jpg') returning id into s_ali;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id)
    values ('Zz166 David Wood','David','Wood','adult',ua,true,'ok','blue',1,u_dav) returning id into s_dav;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id)
    values ('Zz166 Eve Eve','Eve','Eve','adult',ua,true,'ok','white',0,u_eve) returning id into s_eve;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, leaderboard_hidden)
    values ('Zz166 Hank Hide','Hank','Hide','adult',ua,true,'ok','white',0,u_hank,true) returning id into s_hank;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id)
    values ('Zz166 Pat Peer','Pat','Peer','adult',ua,true,'ok','white',0,u_peer) returning id into s_peer;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, leaderboard_hidden)
    values ('Zz166 Kit Kay','Kit','Kay','kids',ua,true,'ok','grey',0,true) returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree)
    values ('Zz166 Lou Low','Lou','Low','kids',ua,true,'ok','yellow',0) returning id into s_lou;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kit, u_pk, 'active', 'legacy_sync', 'manage'), (s_lou, u_pl, 'active', 'legacy_sync', 'manage');

  -- July 2031: Alison 9, David 7, Eve 5, Kit 4, Lou 3 (one class a day from the 1st)
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, date '2031-07-01' + g, '07:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_ali, 9), (s_dav, 7), (s_eve, 5), (s_kit, 4), (s_lou, 3)) x(sid, k), generate_series(0, 8) g
   where g < x.k;
  -- March 2001: Alison 6, David 5, Eve 4, Hank 3
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, date '2001-03-01' + g, '07:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_ali, 6), (s_dav, 5), (s_eve, 4), (s_hank, 3)) x(sid, k), generate_series(0, 5) g
   where g < x.k;

  -- 1. a member (David) sees Alison's spot as Anonymous, with nothing that identifies her
  v := pg_temp.board(u_dav, comp, 'adult');
  if v <> '1:Anonymous:true | 2:David Wood:false | 3:Eve Eve:false' then raise exception 'FAIL 1: %', v; end if;
  perform pg_temp.v_as(u_dav);
  select * into r from public.competition_standings(comp, null, null) s where s.rank = 1 and s.audience = 'adult';
  execute 'reset role';
  if r.student_id is not null or r.photo_url is not null or r.belt is not null or r.degree is not null
     or r.class_points is not null or r.gi_points is not null or r.nogi_points is not null or r.award_points is not null
     or r.referral_points is not null or r.checkin_points is not null or r.classes_count is not null
     or r.last_scored_on is not null or r.prize_eligible is not null or r.leaderboard_hidden is not null
     or r.points <> 9 or r.prize_rank <> 1 or r.minor is not false or r.unit_id <> ua or r.division_id is null then
    raise exception 'FAIL 1: the Anonymous row carries more than rank / prize / points / division: %', row_to_json(r);
  end if;
  raise notice 'PASS 1: David sees % (Anonymous: rank 1, prize 1, 9 points; no id, photo, belt, degree or parts); no hole', v;

  -- 2. Alison sees herself normally
  v := pg_temp.board(u_ali, comp, 'adult');
  if v <> '1:Alison Lee:false | 2:David Wood:false | 3:Eve Eve:false' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: Alison sees herself: %', v;

  -- 3. staff see the real row (and her hidden flag)
  perform pg_temp.v_as(u_stf);
  select format('%s:%s:%s:%s', s.rank, s.display_name, s.leaderboard_hidden::text, s.is_anonymous::text) into v
    from public.competition_standings(comp, null, null) s where s.student_id = s_ali;
  execute 'reset role';
  if v <> '1:Alison Lee:true:false' then raise exception 'FAIL 3: %', v; end if;
  raise notice 'PASS 3: staff see the real row: %', v;

  -- 4. kids: a guardian sees their own hidden kid; another guardian sees Anonymous; a
  --    member with no kids gets no kids rows at all (the kids visibility rule)
  v := pg_temp.board(u_pk, comp, 'kids') || ' || ' || pg_temp.board(u_pl, comp, 'kids') || ' || ' || pg_temp.board(u_peer, comp, 'kids');
  if v <> '1:Kit K.:false | 2:Lou L.:false || 1:Anonymous:true | 2:Lou L.:false || -' then raise exception 'FAIL 4: %', v; end if;
  raise notice 'PASS 4: kids: Kit''s guardian | Lou''s guardian | no kids: %', v;

  -- 5. the TV race: Anonymous in the spot; the name and photo nowhere
  update public.classes k set active = false where k.unit_id = ua and k.day_of_week = 3;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 3, '18:00', 'alev', 60, 'Adults', true, 'Gi', 'All Levels', 'zz166') returning id into cls;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id, arrived_at)
    values (s_ali, cls, '2031-07-16', '18:00', 'alev', 'going', 1.00, 'gi', ua, '2031-07-16 07:40+00'),
           (s_dav, cls, '2031-07-16', '18:00', 'alev', 'going', 1.00, 'gi', ua, null);
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz166 tv', ua, encode(sha256('zz166'::bytea), 'hex'), true) returning id into scr;
  p := public._tv_payload(scr, '2031-07-16', '17:55');
  select string_agg(format('%s:%s:%s', e ->> 'rank', e ->> 'name', coalesce(e ->> 'anonymous', 'false')), ' | ' order by (e ->> 'rank')::int) into v
    from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') e where (e ->> 'rank')::int <= 3;
  if v <> '1:Anonymous:true | 2:David Wood:false | 3:Eve Eve:false'
     or p::text like '%Alison%' or p::text like '%ali.jpg%'
     or exists (select 1 from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') e
                 where e ->> 'name' = 'Anonymous' and (e ->> 'belt' is not null or e ->> 'photo_path' is not null or e ? 'sid')) then
    raise exception 'FAIL 5: %', v;
  end if;
  raise notice 'PASS 5: TV race %; the hidden name, photo and belt nowhere in the payload', v;

  -- 6. the TV Up next, the going list and arrivals never include the hidden member
  select string_agg(x ->> 'name', ',') into v from jsonb_array_elements(p -> 'up_next') b, jsonb_array_elements(b -> 'people') x;
  if coalesce(v, '') <> 'David Wood'
     or exists (select 1 from jsonb_array_elements(p -> 'arrivals') x where x ->> 'name' in ('Anonymous', 'Alison Lee'))
     or exists (select 1 from jsonb_array_elements(coalesce(p -> 'next_class' -> 'going', '[]'::jsonb)) x where x ->> 'name' in ('Anonymous', 'Alison Lee'))
     or (select (b ->> 'on_the_way')::int + (b ->> 'here')::int from jsonb_array_elements(p -> 'up_next') b limit 1) <> 1 then
    raise exception 'FAIL 6: up next % / arrivals % / going %', p -> 'up_next', p -> 'arrivals', p -> 'next_class' -> 'going';
  end if;
  raise notice 'PASS 6: Up next lists only %, no Anonymous; arrivals and the going list without her', v;

  -- 7. the published event: every hidden member is Anonymous in their spot (the
  --    winner as before, and now the non-winner too); no hole
  perform pg_temp.v_as(u_adm);
  perform public.competition_publish(old, '[]'::jsonb);
  execute 'reset role';
  v := pg_temp.board(u_peer, old, 'adult');
  if v <> '1:Anonymous:true | 2:David Wood:false | 3:Eve Eve:false | 4:Anonymous:true' then raise exception 'FAIL 7: %', v; end if;
  v := v || ' || Alison: ' || pg_temp.board(u_ali, old, 'adult');
  if v not like '%Alison: 1:Alison Lee:false | 2:David Wood:false | 3:Eve Eve:false | 4:Anonymous:true' then raise exception 'FAIL 7: %', v; end if;
  raise notice 'PASS 7: published: %', v;

  -- 8. the return type ends with is_anonymous; the grants are 165's
  if pg_get_function_result('public.competition_standings(uuid, date, date)'::regprocedure) not like '%, checkin_points numeric, is_anonymous boolean)'
     or has_function_privilege('anon', 'public.competition_standings(uuid, date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_standings(uuid, date, date)', 'execute') then
    raise exception 'FAIL 8: % ', pg_get_function_result('public.competition_standings(uuid, date, date)'::regprocedure);
  end if;
  raise notice 'PASS 8: is_anonymous appended last; authenticated only';
end $$;

rollback;
