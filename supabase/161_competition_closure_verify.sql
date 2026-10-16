-- 161_competition_closure_verify.sql
--
-- Run AFTER 161, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/161_competition_closure_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- The event is in July 2001 (it has really ended, and no real attendance exists
-- then), on the first two units by name. The TV days are closed at the first
-- unit (class_exceptions cast to the real types) so the real timetable never
-- focuses the playlist.
--   adults (first unit): Sam staff 10 classes (rank 1, skipped), Ann 8 (1st prize),
--     Hid hidden 7 (2nd, Anonymous), Tia and Tom 5 each on the same days (tied at
--     3rd, unresolved), Ned 3 (6th, no prize), Zoe 0 points.
--   kids (first unit): Kim 6, Kit 4, Kev 3, Kai 2 (4th, no prize); Kim and Kai
--     share a guardian.

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
create function pg_temp.pl(p jsonb) returns text language sql immutable as $f$
  select string_agg(x ->> 'screen', ',' order by o) from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;

do $$
declare
  ua uuid; ub uuid; comp uuid; comp2 uuid; dva uuid; dvk uuid; dvb uuid; scr uuid; ty jsonb;
  u_adm uuid := gen_random_uuid(); u_stf uuid := gen_random_uuid(); u_sam uuid := gen_random_uuid();
  u_ann uuid := gen_random_uuid(); u_hid uuid := gen_random_uuid(); u_tia uuid := gen_random_uuid();
  u_ned uuid := gen_random_uuid(); u_zoe uuid := gen_random_uuid(); u_gk uuid := gen_random_uuid();
  u_gkit uuid := gen_random_uuid(); u_bee uuid := gen_random_uuid();
  s_sam uuid; s_ann uuid; s_hid uuid; s_tia uuid; s_tom uuid; s_ned uuid; s_zoe uuid;
  s_kim uuid; s_kit uuid; s_kev uuid; s_kai uuid; s_bee uuid;
  p jsonb; v text; n int; m int; e jsonb; res jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz161 Cup', 'event', '2001-07-01', '2001-07-31', '2001-08-01', 'active',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ua, 'adult', 'Zz Adults') returning id into dva;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ua, 'kids', 'Zz Kids') returning id into dvk;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ub, 'adult', 'Zz B Adults') returning id into dvb;
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values (comp, 'class_attended', 1, true);

  insert into auth.users (id, email)
  select x, 'zz161-' || x::text || '@example.invalid' from unnest(array[u_adm, u_stf, u_sam, u_ann, u_hid, u_tia, u_ned, u_zoe, u_gk, u_gkit, u_bee]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz161-' || x.id::text || '@example.invalid', x.nm, x.role, 'approved', x.u
    from (values (u_adm, 'Zz Admin', 'student', ua), (u_stf, 'Zz Staff', 'instructor', ua), (u_sam, 'Zz Sam', 'instructor', ua),
                 (u_ann, 'Zz Ann', 'student', ua), (u_hid, 'Zz Hid', 'student', ua), (u_tia, 'Zz Tia', 'student', ua),
                 (u_ned, 'Zz Ned', 'student', ua), (u_zoe, 'Zz Zoe', 'student', ua), (u_gk, 'Zz Guardian', 'parent', ua),
                 (u_gkit, 'Zz Guardian 2', 'parent', ua), (u_bee, 'Zz Bee', 'student', ub)) x(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_adm) on conflict do nothing;

  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, prize_eligible)
    values ('Zz161 Sam Staff','Sam','Staff','adult',ua,true,'ok','black',2,u_sam,false) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, photo_url)
    values ('Zz161 Ann Alpha','Ann','Alpha','adult',ua,true,'ok','purple',1,u_ann,'zz161/ann.jpg') returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, leaderboard_hidden, photo_url)
    values ('Zz161 Hid Den','Hid','Den','adult',ua,true,'ok','brown',3,u_hid,true,'zz161/hid.jpg') returning id into s_hid;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, user_id)
    values ('Zz161 Tia Tie','Tia','Tie','adult',ua,true,'ok','blue',u_tia) returning id into s_tia;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz161 Tom Tie','Tom','Tie','adult',ua,true,'ok','blue') returning id into s_tom;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, user_id)
    values ('Zz161 Ned Six','Ned','Six','adult',ua,true,'ok','white',u_ned) returning id into s_ned;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz161 Zoe Zero','Zoe','Zero','adult',ua,true,'ok',u_zoe) returning id into s_zoe;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz161 Kim Kid','Kim','Kid','kids',ua,true,'ok','grey/white') returning id into s_kim;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz161 Kit Kid','Kit','Kid','kids',ua,true,'ok','yellow') returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz161 Kev Kid','Kev','Kid','kids',ua,true,'ok','white') returning id into s_kev;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz161 Kai Kid','Kai','Kid','kids',ua,true,'ok','white') returning id into s_kai;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz161 Bee Bunit','Bee','Bunit','adult',ub,true,'ok',u_bee) returning id into s_bee;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kim, u_gk, 'active', 'legacy_sync', 'manage'), (s_kai, u_gk, 'active', 'legacy_sync', 'manage'),
    (s_kit, u_gkit, 'active', 'legacy_sync', 'manage');
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, date '2001-07-01' + g, '18:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_sam, 10), (s_ann, 8), (s_hid, 7), (s_tia, 5), (s_tom, 5), (s_ned, 3),
                 (s_kim, 6), (s_kit, 4), (s_kev, 3), (s_kai, 2), (s_bee, 1)) x(sid, k)
   cross join generate_series(0, 29) g
   where g < x.k;

  -- TV days closed at the first unit (no class can focus the playlist)
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind)
                  select $1::text::%s, d::text::%s, ''closed''::text::%s
                    from unnest(array[''2001-07-15'', ''2001-08-05'', ''2001-08-10'', ''2001-08-25'', ''2001-09-05'']) d',
                 ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind') using ua;
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz161 tv', ua, encode(sha256('zz161'::bytea), 'hex')) returning id into scr;

  -- 1. grants
  if has_function_privilege('anon', 'public.competition_publish(uuid, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.competition_review(uuid)', 'execute')
     or has_function_privilege('anon', 'public.competition_champions()', 'execute')
     or has_function_privilege('authenticated', 'public._competition_close_rows(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_champions()', 'execute') then
    raise exception 'FAIL 1: grants';
  end if;
  raise notice 'PASS 1: review / publish / champions for authenticated (owner checked inside); internals closed';

  -- 2. provisional: nothing for a member, everything for staff
  perform pg_temp.v_as(u_tia);
  select count(*) into n from public.competition_standings(comp, null, null);
  execute 'reset role';
  perform pg_temp.v_as(u_stf);
  select count(*) into m from public.competition_standings(comp, null, null);
  execute 'reset role';
  if n <> 0 or m = 0 then raise exception 'FAIL 2: member % rows, staff % rows', n, m; end if;
  raise notice 'PASS 2: provisional: a member sees 0 rows, staff % rows', m;

  -- 3. review: staff skipped, hidden, unresolved tie; owner only
  perform pg_temp.v_as(u_stf);
  begin
    perform public.competition_review(comp);
    v := 'accepted';
  exception when insufficient_privilege then v := 'refused';
  end;
  execute 'reset role';
  if v <> 'refused' then raise exception 'FAIL 3: staff ran the review'; end if;
  perform pg_temp.v_as(u_adm);
  create temp table rv161 on commit drop as select * from public.competition_review(comp);
  execute 'reset role';
  select string_agg(format('%s:%s/%s%s%s%s', r.real_name, r.rank, coalesce(r.prize_rank::text, '-'),
                           case when not r.prize_eligible then ' staff' else '' end,
                           case when r.leaderboard_hidden then ' hidden' else '' end,
                           case when r.tie_unresolved then ' TIE' else '' end), ' | ' order by r.rank, r.real_name)
    into v from rv161 r where r.division_id = dva;
  if v <> 'Sam Staff:1/- staff | Ann Alpha:2/1 | Hid Den:3/2 hidden | Tia Tie:4/3 TIE | Tom Tie:4/3 TIE' then
    raise exception 'FAIL 3: %', v;
  end if;
  raise notice 'PASS 3: review adults: %', v;

  -- 4. publish: refused with the tie open; "both" gives both the place
  perform pg_temp.v_as(u_adm);
  begin
    perform public.competition_publish(comp, '[]');
    v := 'accepted';
  exception when invalid_parameter_value then v := sqlerrm;
  end;
  execute 'reset role';
  if v not like 'unresolved tie: Zz Adults 3rd%' then raise exception 'FAIL 4: %', v; end if;
  begin
    perform pg_temp.v_as(u_adm);
    perform public.competition_publish(comp, jsonb_build_array(jsonb_build_object('division_id', dva, 'prize_rank', 3, 'both', true)));
    execute 'reset role';
    select string_agg(cr.prize_rank::text, ',' order by cr.student_id) into v
      from public.competition_results cr where cr.competition_id = comp and cr.student_id in (s_tia, s_tom);
    raise exception 'zz161 undo both' using errcode = 'P0161', detail = v;
  exception when sqlstate 'P0161' then
    execute 'reset role';
    get stacked diagnostics v = pg_exception_detail;
  end;
  if v <> '3,3' then raise exception 'FAIL 4: both -> %', v; end if;
  if exists (select 1 from public.competitions where id = comp and published_at is not null) then raise exception 'FAIL 4: undo leaked'; end if;
  raise notice 'PASS 4: publish refused with the tie open (%); "both": Tia and Tom both 3rd', 'unresolved tie: Zz Adults 3rd';

  -- 5. publish with a winner: Tia 3rd, Tom 4th; then final (a second publish refused)
  perform pg_temp.v_as(u_adm);
  res := public.competition_publish(comp, jsonb_build_array(jsonb_build_object('division_id', dva, 'prize_rank', 3, 'winner', s_tia)));
  begin
    perform public.competition_publish(comp, '[]');
    v := 'accepted';
  exception when invalid_parameter_value then v := sqlerrm;
  end;
  execute 'reset role';
  if (select prize_rank from public.competition_results where competition_id = comp and student_id = s_tia) <> 3
     or (select prize_rank from public.competition_results where competition_id = comp and student_id = s_tom) <> 4
     or v <> 'results already published'
     or (select results_until from public.competitions where id = comp) <> '2001-08-31'
     or (select published_by from public.competitions where id = comp) <> u_adm then
    raise exception 'FAIL 5: % / %', res, v;
  end if;
  raise notice 'PASS 5: published (%): Tia 3rd, Tom 4th; results_until 2001-08-31; a second publish refused', res;

  -- 6. frozen: a late attendance changes the live score, never the board
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s_tom, null, '2001-07-29', '18:00', 'alev', 'present', 1.00, 'gi', ua),
           (s_tom, null, '2001-07-30', '18:00', 'alev', 'present', 1.00, 'gi', ua);
  perform pg_temp.v_as(u_tia);
  create temp table fb161 on commit drop as select * from public.competition_standings(comp, null, null);
  execute 'reset role';
  if (select points from fb161 where student_id = s_tom) <> 5
     or (select s.points from public._competition_scores(comp, null, null) s where s.student_id = s_tom) <> 7 then
    raise exception 'FAIL 6: frozen % live %', (select points from fb161 where student_id = s_tom),
      (select s.points from public._competition_scores(comp, null, null) s where s.student_id = s_tom);
  end if;
  select string_agg(format('%s:%s/%s:%s:%s', coalesce(f.display_name, '?'), f.rank, coalesce(f.prize_rank::text, '-'),
                           coalesce(f.belt, 'nobelt'), coalesce(f.student_id::text, 'noid') = 'noid'), ' | ' order by f.rank, f.display_name)
    into v from fb161 f where f.division_id = dva and f.rank <= 4;
  -- name:rank/prize:belt:id hidden (the hidden winner is Anonymous: no id, no belt)
  if v <> 'Sam Staff:1/-:black:f | Ann Alpha:2/1:purple:f | Anonymous:3/2:nobelt:t | Tia Tie:4/3:blue:f | Tom Tie:4/4:blue:f' then
    raise exception 'FAIL 6: board %', v;
  end if;
  if exists (select 1 from fb161 where audience = 'kids') then raise exception 'FAIL 6: kids rows for an adult member'; end if;
  raise notice 'PASS 6: frozen board (Tom 5, live 7): %', v;

  -- 7. notifications
  select string_agg(format('%s: %s / %s', u.full_name, nf.title, nf.body), E'\n' order by u.full_name, nf.title) into v
    from public.notifications nf join public.users u on u.id = nf.user_id
   where nf.type = 'competition_result' and nf.user_id in (u_adm, u_stf, u_sam, u_ann, u_hid, u_tia, u_ned, u_zoe, u_gk, u_gkit);
  if v is distinct from concat_ws(E'\n',
       'Zz Ann: You won 1st prize in the Zz161 Cup / Zz Adults, 8 points. Congratulations, the team will be in touch about your prize.',
       'Zz Guardian: Kai finished 4th in the Zz161 Cup / Zz Kids, 2 points. Well done Kai!',
       'Zz Guardian: Kim won 1st prize in the Zz161 Cup / Zz Kids, 6 points. Well done Kim!',
       'Zz Guardian 2: Kit won 2nd prize in the Zz161 Cup / Zz Kids, 4 points. Well done Kit!',
       'Zz Hid: You won 2nd prize in the Zz161 Cup / Zz Adults, 7 points. Congratulations, the team will be in touch about your prize. You''re hidden on the board, so you show as Anonymous.',
       'Zz Ned: Zz161 Cup results / You finished 6th in Zz Adults with 3 points. Thanks for training!',
       'Zz Tia: You won 3rd prize in the Zz161 Cup / Zz Adults, 5 points. Congratulations, the team will be in touch about your prize.') then
    raise exception E'FAIL 7:\n%', v;
  end if;
  raise notice 'PASS 7: notifications: scorer, prizes, kids to their guardians (two kids, two messages), hidden says Anonymous; none for staff (Sam) or 0 points (Zoe)';

  -- 8. champions: adults only, Anonymous for the hidden winner
  perform pg_temp.v_as(u_bee);
  select string_agg(format('%s %s %s %s %s', c.division_label, c.place, c.display_name, coalesce(c.belt, 'nobelt'), coalesce(c.photo_url, 'nophoto')), ' | ' order by c.division_label, c.place)
    into v from public.competition_champions() c where c.competition_id = comp;
  execute 'reset role';
  if v <> 'Zz Adults 1 Ann Alpha purple zz161/ann.jpg | Zz Adults 2 Anonymous nobelt nophoto | Zz Adults 3 Tia Tie blue nophoto | Zz B Adults 1 Bee Bunit nobelt nophoto' then
    raise exception 'FAIL 8: %', v;
  end if;
  raise notice 'PASS 8: champions (adults only, hidden = Anonymous): %', v;

  -- 9. Oss on a champions card: a member of that unit; not another unit; never a kids division
  perform pg_temp.v_as(u_tia);
  res := public.toggle_oss('champions', dva);
  select count(*) into n from public.wall_reactions where target_type = 'champions' and target_id = dva;
  begin
    perform public.toggle_oss('champions', dvk);
    v := 'accepted';
  exception when others then v := sqlerrm;
  end;
  execute 'reset role';
  if (res ->> 'reacted')::boolean is not true or (res ->> 'count')::int <> 1 or n <> 1 or v <> 'target not visible' then
    raise exception 'FAIL 9: % rows % kids %', res, n, v;
  end if;
  perform pg_temp.v_as(u_bee);
  begin
    perform public.toggle_oss('champions', dva);
    v := 'accepted';
  exception when others then v := sqlerrm;
  end;
  execute 'reset role';
  if v <> 'target not visible' then raise exception 'FAIL 9: another unit: %', v; end if;
  raise notice 'PASS 9: Oss on the champions card (member of the unit, visible on reload); another unit and a kids division refused';

  -- 10. TV
  p := public._tv_payload(scr, '2001-07-15', '10:00');
  if p -> 'competition' ->> 'name' <> 'Zz161 Cup' or p -> 'competition' ->> 'phase' <> 'live' or p -> 'cup' <> 'null'::jsonb then
    raise exception 'FAIL 10: during the event %', p -> 'competition';
  end if;
  p := public._tv_payload(scr, '2001-08-10', '10:00');
  v := pg_temp.pl(p);
  if p -> 'competition' ->> 'kind' <> 'monthly' or p -> 'cup' ->> 'phase' <> 'published'
     or v !~ 'cup_champions_adult' or v !~ 'cup_over_adult' or v !~ 'cup_champions_kids' or v !~ 'cup_over_kids'
     or v ~ '(^|,)(battle|feed|last_results)(,|$)'
     or p -> 'cup' -> 'adult' -> 'champions' -> 1 ->> 'name' <> 'Anonymous'
     or p -> 'cup' -> 'adult' -> 'champions' -> 1 ->> 'photo_path' is not null
     or p -> 'cup' -> 'adult' -> 'champions' -> 1 ->> 'belt' is not null
     or p -> 'cup' -> 'kids' -> 'champions' -> 0 ->> 'photo_path' is not null
     or (p -> 'cup' -> 'adult' -> 'numbers' ->> 'members')::int <> 6
     or (select sum((x ->> 'seconds')::int) from jsonb_array_elements(p -> 'playlist') x) <> 90 then
    raise exception 'FAIL 10: published % / %', v, p -> 'cup';
  end if;
  raise notice 'PASS 10: during the event the Cup is the board; after it the monthly race with %', v;
  p := public._tv_payload(scr, '2001-09-05', '10:00');
  if p -> 'cup' <> 'null'::jsonb or pg_temp.pl(p) ~ 'cup_' then raise exception 'FAIL 10: after results_until %', p -> 'cup'; end if;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz161 Next', 'event', '2001-08-20', '2001-08-30', 'active', '[]') returning id into comp2;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp2, ua, 'adult', 'Zz next');
  p := public._tv_payload(scr, '2001-08-25', '10:00');
  if p -> 'cup' <> 'null'::jsonb or p -> 'competition' ->> 'name' <> 'Zz161 Next' then raise exception 'FAIL 10: another event %', p -> 'cup'; end if;
  raise notice 'PASS 10.1: after results_until, or once another event starts, no Cup screens';
end $$;

-- 11. provisional on the TV (a second event, nothing published)
do $$
declare ua uuid; comp uuid; scr uuid; p jsonb; v text; s uuid; ty jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz161 Prov', 'event', '2002-07-01', '2002-07-31', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp, ua, 'adult', 'Zz P adults');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values (comp, 'class_attended', 1, true);
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz161 Pro Vis','Pro','Vis','adult',ua,true,'ok') returning id into s;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s, null, '2002-07-03', '18:00', 'alev', 'present', 1.00, 'gi', ua);
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind) values ($1::text::%s, ''2002-08-05''::text::%s, ''closed''::text::%s)',
                 ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind') using ua;
  select id into scr from public.tv_screens where name = 'zz161 tv';
  p := public._tv_payload(scr, '2002-08-05', '10:00');
  v := pg_temp.pl(p);
  if p -> 'cup' ->> 'phase' <> 'provisional' or v !~ 'cup_over_adult' or v ~ 'cup_champions' or v ~ 'cup_over_kids'
     or p -> 'cup' -> 'adult' -> 'champions' <> '[]'::jsonb or p -> 'competition' ->> 'kind' <> 'monthly' then
    raise exception 'FAIL 11: % / %', v, p -> 'cup';
  end if;
  raise notice 'PASS 11: provisional on the TV: % (no champions, kids screen only when kids scored)', v;
end $$;

rollback;
