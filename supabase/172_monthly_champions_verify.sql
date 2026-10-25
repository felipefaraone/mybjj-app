-- 172_monthly_champions_verify.sql
--
-- Run AFTER 172, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/172_monthly_champions_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (the closes, the
-- notifications and the Oss below included). Every test prints "PASS ..."
-- (NOTICE); the first failure stops it with "FAIL ...".
-- The month is July 2001 of the REAL monthly race (the one the TV reads): it
-- has really ended and no real attendance exists then. Unit A has an adult and
-- a kids division of the race, unit B an adult one.
--   adults (A): Sam staff 10 classes (rank 1, skipped), Ann 8 (1st), Hid hidden 7
--     (2nd, Anonymous), Tia and Tom 5 each on the same days (both 3rd), Ned 3
--     (6th, nothing), Zoe 0 points.
--   kids (A): Kim 6, Kit 4, Kev 3 (no guardian), Kai 4th; Kim and Kai share a guardian.
--   adults (B): Bee 1 (1st).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
-- the TV's last month, one audience: "name/staff" by rank
create function pg_temp.tv_last(p jsonb, aud text) returns text language sql immutable as $f$
  select string_agg((x ->> 'name') || case when (x ->> 'staff')::boolean then '/staff' else '' end, ', ' order by o)
    from jsonb_array_elements(p -> 'last_results' -> aud) with ordinality t(x, o)
$f$;

do $$
declare
  mc uuid; ua uuid; ub uuid; dva uuid; dvk uuid; dvb uuid; scr uuid; ty jsonb;
  u_sam uuid := gen_random_uuid(); u_ann uuid := gen_random_uuid(); u_hid uuid := gen_random_uuid();
  u_tia uuid := gen_random_uuid(); u_ned uuid := gen_random_uuid(); u_zoe uuid := gen_random_uuid();
  u_gk uuid := gen_random_uuid(); u_gkit uuid := gen_random_uuid(); u_bee uuid := gen_random_uuid();
  zz uuid[];
  s_sam uuid; s_ann uuid; s_hid uuid; s_tia uuid; s_tom uuid; s_ned uuid; s_zoe uuid;
  s_kim uuid; s_kit uuid; s_kev uuid; s_kai uuid; s_bee uuid;
  p jsonb; v text; w text; n int; m int; res jsonb; cup1 text; cup2 text; t_jul uuid; t_aug uuid;
begin
  select id into mc from public.competitions where kind = 'monthly' and status = 'active' order by created_at, id limit 1;
  if mc is null then raise exception 'FAIL setup: no active monthly competition'; end if;
  select d.unit_id into ua from public.competition_divisions d where d.competition_id = mc
   group by d.unit_id having count(distinct d.audience) = 2 order by d.unit_id limit 1;
  select d.unit_id into ub from public.competition_divisions d where d.competition_id = mc and d.audience = 'adult' and d.unit_id <> ua
   order by d.unit_id limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: the monthly race needs a unit with adults and kids and a second unit'; end if;
  select id into dva from public.competition_divisions where competition_id = mc and unit_id = ua and audience = 'adult';
  select id into dvk from public.competition_divisions where competition_id = mc and unit_id = ua and audience = 'kids';
  select id into dvb from public.competition_divisions where competition_id = mc and unit_id = ub and audience = 'adult';
  if exists (select 1 from public.competition_month_closes where competition_id = mc and period_from in ('2001-06-01', '2001-07-01', '2001-08-01')) then
    raise exception 'FAIL setup: 2001 months already published';
  end if;

  insert into auth.users (id, email)
  select x, 'zz172-' || x::text || '@example.invalid' from unnest(array[u_sam, u_ann, u_hid, u_tia, u_ned, u_zoe, u_gk, u_gkit, u_bee]) x;
  insert into public.users (id, email, full_name, role, status, unit_id)
  select x.id, 'zz172-' || x.id::text || '@example.invalid', x.nm, x.role, 'approved', x.u
    from (values (u_sam, 'Zz Sam', 'instructor', ua), (u_ann, 'Zz Ann', 'student', ua), (u_hid, 'Zz Hid', 'student', ua),
                 (u_tia, 'Zz Tia', 'student', ua), (u_ned, 'Zz Ned', 'student', ua), (u_zoe, 'Zz Zoe', 'student', ua),
                 (u_gk, 'Zz Guardian', 'parent', ua), (u_gkit, 'Zz Guardian 2', 'parent', ua), (u_bee, 'Zz Bee', 'student', ub)) x(id, nm, role, u)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  zz := array[u_sam, u_ann, u_hid, u_tia, u_ned, u_zoe, u_gk, u_gkit, u_bee];

  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, prize_eligible)
    values ('Zz172 Sam Staff','Sam','Staff','adult',ua,true,'ok','black',2,u_sam,false) returning id into s_sam;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, photo_url)
    values ('Zz172 Ann Alpha','Ann','Alpha','adult',ua,true,'ok','purple',1,u_ann,'zz172/ann.jpg') returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, user_id, leaderboard_hidden, photo_url)
    values ('Zz172 Hid Den','Hid','Den','adult',ua,true,'ok','brown',3,u_hid,true,'zz172/hid.jpg') returning id into s_hid;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, user_id)
    values ('Zz172 Tia Tie','Tia','Tie','adult',ua,true,'ok','blue',u_tia) returning id into s_tia;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz172 Tom Tie','Tom','Tie','adult',ua,true,'ok','blue') returning id into s_tom;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, user_id)
    values ('Zz172 Ned Six','Ned','Six','adult',ua,true,'ok','white',u_ned) returning id into s_ned;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz172 Zoe Zero','Zoe','Zero','adult',ua,true,'ok',u_zoe) returning id into s_zoe;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz172 Kim Kid','Kim','Kid','kids',ua,true,'ok','grey/white') returning id into s_kim;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz172 Kit Kid','Kit','Kid','kids',ua,true,'ok','yellow') returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz172 Kev Kid','Kev','Kid','kids',ua,true,'ok','white') returning id into s_kev;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz172 Kai Kid','Kai','Kid','kids',ua,true,'ok','white') returning id into s_kai;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz172 Bee Bunit','Bee','Bunit','adult',ub,true,'ok',u_bee) returning id into s_bee;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_kim, u_gk, 'active', 'legacy_sync', 'manage'), (s_kai, u_gk, 'active', 'legacy_sync', 'manage'),
    (s_kit, u_gkit, 'active', 'legacy_sync', 'manage');
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, date '2001-07-01' + g, '18:00', 'alev', 'present', 1.00, 'gi', x.u
    from (values (s_sam, 10, ua), (s_ann, 8, ua), (s_hid, 7, ua), (s_tia, 5, ua), (s_tom, 5, ua), (s_ned, 3, ua),
                 (s_kim, 6, ua), (s_kit, 4, ua), (s_kev, 3, ua), (s_kai, 2, ua), (s_bee, 1, ub)) x(sid, k, u)
   cross join generate_series(0, 29) g
   where g < x.k;

  -- TV days closed at unit A (no class can focus the playlist)
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  execute format('insert into public.class_exceptions (unit_id, exception_date, kind)
                  select $1::text::%s, d::text::%s, ''closed''::text::%s from unnest(array[''2001-08-03'']) d',
                 ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind') using ua;
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz172 tv', ua, encode(sha256('zz172'::bytea), 'hex')) returning id into scr;

  -- 0. structure, grants, the schedule
  if to_regclass('public.competition_month_closes') is null
     or not (select relrowsecurity from pg_class where oid = 'public.competition_month_closes'::regclass)
     or has_table_privilege('authenticated', 'public.competition_month_closes', 'select') then
    raise exception 'FAIL 0: competition_month_closes missing, RLS off or readable by clients';
  end if;
  if has_function_privilege('authenticated', 'public.monthly_close(date)', 'execute')
     or has_function_privilege('anon', 'public.monthly_close(date)', 'execute')
     or has_function_privilege('authenticated', 'public.monthly_close_due()', 'execute')
     or has_function_privilege('authenticated', 'public._competition_month_rows(uuid, date, date)', 'execute')
     or has_function_privilege('authenticated', 'public._month_champions(uuid, date)', 'execute')
     or has_function_privilege('anon', 'public.competition_month_champions()', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_month_champions()', 'execute') then
    raise exception 'FAIL 0: grants';
  end if;
  select format('%s | %s | %s', j.schedule, j.command, j.active) into v from cron.job j where j.jobname = 'monthly-close';
  if v is distinct from '0 * 2-4 * * | select public.monthly_close_due() | true' then
    raise exception 'FAIL 0: cron job monthly-close is %', v;
  end if;
  raise notice 'PASS 0: table (RLS, no client read), grants (close internal, champions for authenticated), cron %', v;

  -- 1. the time zone: 09:00 Sydney on the 3rd, summer (UTC+11) and winter (UTC+10)
  select string_agg(coalesce(public._monthly_close_due_month(t)::text, '-'), ' ' order by t) into v
    from unnest(array['2026-11-01 22:00+00', '2026-11-02 21:59+00', '2026-11-02 22:00+00', '2026-11-02 23:00+00',
                      '2026-12-02 22:00+00', '2027-06-02 22:00+00', '2027-06-02 23:00+00']::timestamptz[]) t;
  if v <> '- - 2026-10-01 2026-10-01 2026-11-01 - 2027-05-01' then raise exception 'FAIL 1: %', v; end if;
  raise notice 'PASS 1: due month by Sydney time (2 Nov 09:00, 3 Nov 08:59, 3 Nov 09:00, 3 Nov 10:00, 3 Dec 09:00, 3 Jun 08:00, 3 Jun 09:00): %', v;

  -- 2. a month that has not ended is refused
  begin
    perform public.monthly_close((now() at time zone 'Australia/Sydney')::date);
    v := 'accepted';
  exception when invalid_parameter_value then v := sqlerrm;
  end;
  if v not like '%has not ended yet' then raise exception 'FAIL 2: %', v; end if;
  raise notice 'PASS 2: the current month is refused (%)', v;

  -- 3. before the close: the TV reads the live month; the Cup's champions as they are
  p := public._tv_payload(scr, '2001-08-03', '10:00');
  v := pg_temp.tv_last(p, 'adult');
  if v is distinct from 'Sam Staff/staff, Ann Alpha, Anonymous' then raise exception 'FAIL 3: TV before the close %', v; end if;
  perform pg_temp.v_as(u_tia);
  select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) into cup1 from public.competition_champions() x;
  execute 'reset role';
  raise notice 'PASS 3: before the close the TV''s July is live: %', v;

  -- 4. the close: the board's ranking, prize_rank skipping staff, ties shared
  res := public.monthly_close('2001-07-15');
  select string_agg(format('%s:%s/%s', s.first_name, cr.rank, coalesce(cr.prize_rank::text, '-')), ' | ' order by cr.rank, s.first_name)
    into v from public.competition_results cr join public.students s on s.id = cr.student_id
   where cr.competition_id = mc and cr.period_from = '2001-07-01' and cr.period_to = '2001-07-31'
     and cr.division_id = dva and s.full_name like 'Zz172 %' and cr.points > 0;
  select string_agg(format('%s:%s/%s', s.first_name, cr.rank, coalesce(cr.prize_rank::text, '-')), ' | ' order by cr.rank, s.first_name)
    into w from public.competition_results cr join public.students s on s.id = cr.student_id
   where cr.competition_id = mc and cr.period_from = '2001-07-01' and cr.division_id = dvk and s.full_name like 'Zz172 %';
  if v is distinct from 'Sam:1/- | Ann:2/1 | Hid:3/2 | Tia:4/3 | Tom:4/3 | Ned:6/5'
     or w is distinct from 'Kim:1/1 | Kit:2/2 | Kev:3/3 | Kai:4/4'
     or not exists (select 1 from jsonb_array_elements(res) e where (e ->> 'competition_id')::uuid = mc and not (e ->> 'already_published')::boolean)
     or not exists (select 1 from public.competition_month_closes where competition_id = mc and period_from = '2001-07-01'
                     and period_to = '2001-07-31' and result_rows > 0 and notifications = 6) then
    raise exception 'FAIL 4: adults % / kids % / %', v, w, res;
  end if;
  raise notice 'PASS 4: July closed: adults % ; kids %', v, w;

  -- 5. a second call does nothing and says so
  select count(*), max(finalized_at)::text into n, w from public.competition_results where competition_id = mc and period_from = '2001-07-01';
  select count(*) into m from public.notifications where user_id = any (zz);
  res := public.monthly_close('2001-07-01');
  if not exists (select 1 from jsonb_array_elements(res) e where (e ->> 'competition_id')::uuid = mc and (e ->> 'already_published')::boolean)
     or (select count(*) from public.competition_results where competition_id = mc and period_from = '2001-07-01') <> n
     or (select max(finalized_at)::text from public.competition_results where competition_id = mc and period_from = '2001-07-01') <> w
     or (select count(*) from public.notifications where user_id = any (zz)) <> m then
    raise exception 'FAIL 5: %', res;
  end if;
  raise notice 'PASS 5: second call: % (rows, snapshot time and notifications unchanged)', res;

  -- 6. notifications: the top 3 of every division, kids to their guardians, nobody else
  select string_agg(format('%s: %s', u.full_name, nf.title), E'\n' order by u.full_name, nf.title) into v
    from public.notifications nf join public.users u on u.id = nf.user_id
   where nf.user_id = any (zz);
  if v is distinct from concat_ws(E'\n',
       'Zz Ann: You finished 1st in the July race',
       'Zz Bee: You finished 1st in the July race',
       'Zz Guardian: Kim finished 1st in the July race',
       'Zz Guardian 2: Kit finished 2nd in the July race',
       'Zz Hid: You finished 2nd in the July race',
       'Zz Tia: You finished 3rd in the July race') then
    raise exception E'FAIL 6:\n%', v;
  end if;
  if (select count(*) from public.notifications where user_id = any (zz) and (type <> 'competition_result' or related_entity_type <> 'competition_result')) > 0
     or (select body from public.notifications where user_id = u_ann) not like '%points. Congratulations! You''re on the July champions card on the Wall.'
     or (select body from public.notifications where user_id = u_hid) not like '%You''re hidden on the board, so you show as Anonymous.'
     or (select body from public.notifications where user_id = u_gk) not like '%Well done Kim!'
     or (select (metadata ->> 'student_id')::uuid from public.notifications where user_id = u_gk) <> s_kim
     or (select related_entity_id from public.notifications where user_id = u_ann)
        <> (select id from public.competition_results where competition_id = mc and period_from = '2001-07-01' and student_id = s_ann) then
    raise exception 'FAIL 6: type, body or entity';
  end if;
  raise notice 'PASS 6: notified: Ann, Hid (Anonymous note), Tia, Bee, Kim and Kit via their guardians; not Sam (staff), Tom and Kev (no account), Ned, Kai (4th), Zoe';

  -- 7. the Wall: adults only, top 3 per unit, staff skipped, hidden = Anonymous
  select string_agg(format('%s %s %s %s', c.title, c.place, coalesce(s.first_name, c.display_name), coalesce(c.belt, 'nobelt')),
                    ' | ' order by (c.unit_id = ua) desc, c.place, s.first_name)
    into v from public._month_champions(mc, '2001-07-01') c left join public.students s on s.id = c.student_id
   where c.division_id in (dva, dvb) and (c.student_id is null or s.full_name like 'Zz172 %');
  if v is distinct from 'July champions 1 Ann purple | July champions 2 Anonymous nobelt | July champions 3 Tia blue | July champions 3 Tom blue | July champions 1 Bee nobelt'
     or exists (select 1 from public._month_champions(mc, '2001-07-01') c where c.division_id not in (select id from public.competition_divisions where audience = 'adult'))
     or exists (select 1 from public._month_champions(mc, '2001-07-01') c where c.student_id = s_sam) then
    raise exception 'FAIL 7: %', v;
  end if;
  perform pg_temp.v_as(u_bee);
  select count(*), count(distinct c.period_from), max(c.period_from)::text into n, m, w
    from public.competition_month_champions() c where c.competition_id = mc;
  execute 'reset role';
  if m <> 1 or w <> (select max(period_from)::text from public.competition_month_closes where competition_id = mc) then
    raise exception 'FAIL 7: the Wall shows % month(s), latest %', m, w;
  end if;
  raise notice 'PASS 7: July card: %; the Wall function returns one month, the latest (%)', v, w;

  -- 8. Oss: the target is the month and the division
  t_jul := public._month_champions_target(dva, '2001-07-01');
  perform pg_temp.v_as(u_tia);
  res := public.toggle_oss('month_champions', t_jul);
  select count(*) into n from public.wall_reactions where target_type = 'month_champions' and target_id = t_jul;   -- through the policy
  begin
    perform public.toggle_oss('month_champions', public._month_champions_target(dvk, '2001-07-01'));
    v := 'accepted';
  exception when others then v := sqlerrm;
  end;
  begin
    perform public.toggle_oss('month_champions', public._month_champions_target(dva, '2001-06-01'));
    w := 'accepted';
  exception when others then w := sqlerrm;
  end;
  execute 'reset role';
  if (res ->> 'reacted')::boolean is not true or (res ->> 'count')::int <> 1 or n <> 1
     or v <> 'target not visible' or w <> 'target not visible' then
    raise exception 'FAIL 8: % read % kids % unpublished %', res, n, v, w;
  end if;
  perform pg_temp.v_as(u_bee);
  begin
    perform public.toggle_oss('month_champions', t_jul);
    v := 'accepted';
  exception when others then v := sqlerrm;
  end;
  select count(*) into n from public.wall_reactions where target_type = 'month_champions' and target_id = t_jul;
  execute 'reset role';
  if v <> 'target not visible' or n <> 0 then raise exception 'FAIL 8: another unit: % / reads %', v, n; end if;
  raise notice 'PASS 8: Oss on July''s card (member of the unit, read back through the policy); kids, an unpublished month and another unit refused';

  -- 9. frozen: Ned's late July classes change the live score, never the month
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select s_ned, null, date '2001-07-10' + g, '07:00', 'alev', 'present', 1.00, 'gi', ua from generate_series(0, 19) g;
  if (select rank from public._competition_ranked(mc, '2001-07-01', '2001-07-31') where student_id = s_ned) <> 1
     or (select rank from public.competition_results where competition_id = mc and period_from = '2001-07-01' and student_id = s_ned) <> 6
     or (select rank from public._competition_month_rows(mc, '2001-07-01', '2001-07-31') where student_id = s_ned) <> 6 then
    raise exception 'FAIL 9: live / frozen ranks';
  end if;
  p := public._tv_payload(scr, '2001-08-03', '10:00');
  v := pg_temp.tv_last(p, 'adult');
  if v is distinct from 'Sam Staff/staff, Ann Alpha, Anonymous' then raise exception 'FAIL 9: TV after the close %', v; end if;
  raise notice 'PASS 9: Ned live 1st, frozen 6th; the TV''s July after the close: %', v;

  -- 10. the next month replaces the card; its Oss is its own
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s_ann, null, '2001-08-02', '18:00', 'alev', 'present', 1.00, 'gi', ua);
  perform public.monthly_close('2001-08-01');
  t_aug := public._month_champions_target(dva, '2001-08-01');
  if t_aug = t_jul
     or not exists (select 1 from public._month_champions(mc, '2001-08-01') c where c.student_id = s_ann and c.title = 'August champions' and c.target_id = t_aug) then
    raise exception 'FAIL 10: August card';
  end if;
  perform pg_temp.v_as(u_bee);
  select count(*) into n from public.competition_month_champions() c where c.competition_id = mc and c.period_from = '2001-07-01';
  execute 'reset role';
  if n <> 0 then raise exception 'FAIL 10: July still on the Wall'; end if;
  raise notice 'PASS 10: August closes, its card replaces July''s, with its own Oss target';

  -- 11. the Cup is untouched
  perform pg_temp.v_as(u_tia);
  select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) into cup2 from public.competition_champions() x;
  execute 'reset role';
  if cup1 <> cup2
     or position('''champions''' in (select prosrc from pg_proc where oid = 'public.toggle_oss(text, uuid)'::regprocedure)) = 0 then
    raise exception 'FAIL 11: Cup champions changed';
  end if;
  raise notice 'PASS 11: competition_champions() unchanged by the closes; toggle_oss keeps the Cup''s ''champions''';
end $$;

rollback;
