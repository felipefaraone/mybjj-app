-- 176_race_start_posts_verify.sql
--
-- Run AFTER 176, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/176_race_start_posts_verify.sql
-- One transaction ending in ROLLBACK: nothing persists (posts, Oss and the
-- Zz176 fixtures included). Every test prints "PASS ..." (NOTICE, and the
-- result table at the end); the first failure stops it with "FAIL ...".
-- Fixtures: units "Zz176 A" and "Zz176 B", a monthly race "Zz176 Monthly"
-- (adults and kids in both), events in 2001 (no real event runs then).
-- Fixture checks look at the Zz176 units only: the real Monthly race also posts
-- for the real units on a 1st in 2001, which is right and rolled back.
-- Test 12 removes the fixtures and every post first, then runs the real data.

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
create temp table res176 (n serial, t text);
create function pg_temp.ok(t text) returns void language plpgsql as $f$
begin
  insert into res176 (t) values (t);
  raise notice '%', t;
end $f$;

do $$
declare
  ua uuid; ub uuid; mz uuid; e1 uuid; e2 uuid; e3 uuid; e5 uuid; e6 uuid; e7 uuid; e8 uuid;
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  da uuid; n int; m int; v text; w text; res jsonb; pa uuid; pb uuid; nb uuid; cd uuid;
begin
  -- 0. Objects, RLS, grants, the job and its Sydney time
  if to_regclass('public.competition_start_lines') is null or to_regclass('public.competition_start_posts') is null then
    raise exception 'FAIL 0: tables missing';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.competition_start_lines'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.competition_start_posts'::regclass)
     or exists (select 1 from pg_policy where polrelid in ('public.competition_start_lines'::regclass, 'public.competition_start_posts'::regclass)) then
    raise exception 'FAIL 0: RLS off or a policy exists';
  end if;
  select count(*), string_agg(id::text || '=' || line, '|' order by id) into n, v from public.competition_start_lines where active;
  if n <> 20 or md5(v) <> md5(
       '1=New board, clean slate. Every class counts from today.|2=Everyone starts on zero. Let''s see who shows up.|'
    || '3=The mats are open and the points are live. Go get them.|4=Fresh start for everyone. Old scores don''t count here.|'
    || '5=Day one. The ones who train early lead early.|6=It''s on. Get to class and get on the board.|'
    || '7=Zero for everyone. Your first class puts you on the board.|8=The race is open. Consistency wins this one.|'
    || '9=Show up, train hard, climb the board.|10=New race, new fight for the top three.|11=The board is empty. Fill it.|'
    || '12=Points start now. Who''s taking first this time?|13=The clock is running. Make every session count.|'
    || '14=The starting gun has gone. Don''t give anyone a head start.|15=Champions, defend it. Everyone else, come and take it.|'
    || '16=Check in, train, repeat. The board is watching.|17=A clean sheet for everyone. Make the first mark yours.|'
    || '18=Grab your kit. The chase starts today.|19=Nobody''s ahead yet. Be the first.|20=Small wins every class. Big finish at the end.') then
    raise exception 'FAIL 0: the 20 lines are not the seed, in order (% rows)', n;
  end if;
  if has_table_privilege('anon', 'public.competition_start_lines', 'select,insert,update,delete')
     or has_table_privilege('authenticated', 'public.competition_start_lines', 'select,insert,update,delete')
     or has_table_privilege('anon', 'public.competition_start_posts', 'select,insert,update,delete')
     or has_table_privilege('authenticated', 'public.competition_start_posts', 'select,insert,update,delete')
     or has_function_privilege('anon', 'public._competition_start_post_due(date)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_start_post_due(date)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_start_post_day(timestamptz)', 'execute')
     or has_function_privilege('anon', 'public.competition_start_posts_feed()', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_start_posts_feed()', 'execute')
     or has_function_privilege('anon', 'public._race_start_visible(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public._race_start_visible(uuid)', 'execute') then
    raise exception 'FAIL 0: grants';
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'public.wall_reactions'::regclass and polname = 'wall_reactions_select_race_start') then
    raise exception 'FAIL 0: the race_start wall_reactions policy is missing';
  end if;
  select count(*), max(schedule) into n, v from cron.job where jobname = 'race-start-posts';
  if n <> 1 or v <> '0 18,19 * * *' or current_setting('cron.timezone', true) not in ('GMT', 'UTC') then
    raise exception 'FAIL 0: job % time(s), schedule %, cron.timezone %', n, v, current_setting('cron.timezone', true);
  end if;
  -- the two GMT runs (18:00, 19:00) against 05:00 Sydney: AEST (July), AEDT
  -- (December) and both DST switch days (4 Oct 2026 starts, 5 Apr 2026 ends)
  select string_agg(to_char(t, 'MM-DD HH24:MI"Z"') || '=' || coalesce(public._competition_start_post_day(t)::text, 'none'), ', ' order by t)
    into w
    from unnest(array['2026-07-15 18:00Z', '2026-07-15 19:00Z', '2026-12-15 17:59Z', '2026-12-15 18:00Z',
                      '2026-12-15 19:00Z', '2026-10-03 18:00Z', '2026-04-04 18:00Z', '2026-04-04 19:00Z']::timestamptz[]) t;
  if public._competition_start_post_day('2026-07-15 18:00Z') is not null                      -- 04:00 AEST
     or public._competition_start_post_day('2026-07-15 19:00Z') <> '2026-07-16'                -- 05:00 AEST
     or public._competition_start_post_day('2026-12-15 17:59Z') is not null                    -- 04:59 AEDT
     or public._competition_start_post_day('2026-12-15 18:00Z') <> '2026-12-16'                -- 05:00 AEDT
     or public._competition_start_post_day('2026-12-15 19:00Z') <> '2026-12-16'                -- 06:00 AEDT (re-run, inserts 0)
     or public._competition_start_post_day('2026-10-03 18:00Z') <> '2026-10-04'                -- DST starts: 05:00 AEDT
     or public._competition_start_post_day('2026-04-04 18:00Z') is not null                    -- DST ended: 04:00 AEST
     or public._competition_start_post_day('2026-04-04 19:00Z') <> '2026-04-05'                -- 05:00 AEST
     or (select command from cron.job where jobname = 'race-start-posts')
        <> 'select public._competition_start_post_due(d) from (select public._competition_start_post_day(now()) as d) x where d is not null' then
    raise exception 'FAIL 0: Sydney 05:00 gate or command: %', w;
  end if;
  perform pg_temp.ok('PASS 0: tables, RLS on (no policies), 20 lines in order, grants, race_start policy, job race-start-posts once, 0 18,19 * * * GMT; gate: ' || w);

  -- fixtures
  insert into public.units (name) values ('Zz176 A') returning id into ua;
  insert into public.units (name) values ('Zz176 B') returning id into ub;
  insert into auth.users (id, email) select x, 'zz176-' || x::text || '@example.invalid' from unnest(array[u_a, u_b]) x;
  insert into public.users (id, email, full_name, role, status, unit_id, active_unit_id)
  select x.id, 'zz176-' || x.id::text || '@example.invalid', x.nm, 'student', 'approved', x.u, x.u
    from (values (u_a, 'Zz176 Ann', ua), (u_b, 'Zz176 Bee', ub)) x(id, nm, u)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status,
                                 unit_id = excluded.unit_id, active_unit_id = excluded.active_unit_id;

  insert into public.competitions (name, kind, status) values ('Zz176 Monthly', 'monthly', 'active') returning id into mz;
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz176 Cup', 'event', '2001-03-05', '2001-04-20', '2001-04-21', 'active', '[{"place":1},{"place":2}]') returning id into e1;
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Soon', 'event', '2001-05-06', '2001-05-31', 'active') returning id into e2;   -- day + 5 from 1 May, unit A
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Later', 'event', '2001-05-09', '2001-06-15', 'active') returning id into e3;  -- day + 8 from 1 May, unit B
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Draft', 'event', '2001-09-11', '2001-10-01', 'draft') returning id into e5;
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Missed2', 'event', '2001-10-08', '2001-10-30', 'active') returning id into e6;
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Missed3', 'event', '2001-10-07', '2001-10-30', 'active') returning id into e7;
  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('Zz176 Reuse', 'event', '2001-11-20', '2001-12-10', 'active') returning id into e8;
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
  select x.c, x.u, x.a, x.l, x.s
    from (values (mz, ua, 'adult', 'Zz176 A Adults', 0), (mz, ua, 'kids', 'Zz176 A Kids', 1),
                 (mz, ub, 'adult', 'Zz176 B Adults', 0), (mz, ub, 'kids', 'Zz176 B Kids', 1),
                 (e1, ua, 'adult', 'Zz176 A Adults', 0), (e1, ua, 'kids', 'Zz176 A Kids', 1),
                 (e1, ub, 'adult', 'Zz176 B Adults', 0), (e1, ub, 'kids', 'Zz176 B Kids', 1),
                 (e2, ua, 'adult', 'Zz176 A Adults', 0), (e3, ub, 'adult', 'Zz176 B Adults', 0),
                 (e5, ua, 'adult', 'Zz176 A Adults', 0), (e6, ua, 'adult', 'Zz176 A Adults', 0),
                 (e7, ub, 'adult', 'Zz176 B Adults', 0), (e8, ua, 'adult', 'Zz176 A Adults', 0)) x(c, u, a, l, s);

  -- 1. An event starts: adult divisions only
  n := public._competition_start_post_due('2001-03-05');
  select count(*), string_agg(d.label || ' ' || p.period_from || '..' || p.period_to || ' on ' || p.start_on, ', ' order by d.label)
    into m, v
    from public.competition_start_posts p join public.competition_divisions d on d.id = p.division_id
   where p.competition_id = e1;
  if n <> 2 or m <> 2 or v <> 'Zz176 A Adults 2001-03-05..2001-04-20 on 2001-03-05, Zz176 B Adults 2001-03-05..2001-04-20 on 2001-03-05' then
    raise exception 'FAIL 1: returned %, rows %: %', n, m, v;
  end if;
  perform pg_temp.ok('PASS 1: event start, returned 2: ' || v || ' (no kids)');

  -- 2. A second run inserts nothing
  n := public._competition_start_post_due('2001-03-05');
  m := public._competition_start_post_due('2001-03-06');
  if n <> 0 or m <> 0 or (select count(*) from public.competition_start_posts where competition_id = e1) <> 2 then
    raise exception 'FAIL 2: the second run inserted % (next day %)', n, m;
  end if;
  perform pg_temp.ok('PASS 2: the same day again inserts 0, the next day (missed-run window) inserts 0');

  -- 3. Two units on the same day get different lines
  select p.id, p.line_id::text into pa, v from public.competition_start_posts p where p.competition_id = e1 and p.unit_id = ua;
  select p.id, p.line_id::text into pb, w from public.competition_start_posts p where p.competition_id = e1 and p.unit_id = ub;
  if v = w then
    raise exception 'FAIL 3: both units got line %', v;
  end if;
  perform pg_temp.ok('PASS 3: same day, Zz176 A line ' || v || ', Zz176 B line ' || w);

  -- 5. Monthly 1st with an event within 7 days in one unit
  n := public._competition_start_post_due('2001-05-01');
  select string_agg(d.label || ' ' || p.period_from || '..' || p.period_to, ', ' order by d.label) into v
    from public.competition_start_posts p join public.competition_divisions d on d.id = p.division_id
   where p.competition_id = mz;
  if v is distinct from 'Zz176 B Adults 2001-05-01..2001-05-31' then
    raise exception 'FAIL 5: %', v;
  end if;
  perform pg_temp.ok('PASS 5: 1 May, Zz176 A has an event on 6 May (no post), Zz176 B''s event is on 9 May, day + 8 (posted): ' || v);

  -- 6. Monthly 1st with no event: the whole month
  n := public._competition_start_post_due('2001-07-01');
  select string_agg(d.label || ' ' || p.period_from || '..' || p.period_to || ' on ' || p.start_on, ', ' order by d.label) into v
    from public.competition_start_posts p join public.competition_divisions d on d.id = p.division_id
   where p.competition_id = mz and p.period_from = '2001-07-01';
  if v is distinct from 'Zz176 A Adults 2001-07-01..2001-07-31 on 2001-07-01, Zz176 B Adults 2001-07-01..2001-07-31 on 2001-07-01' then
    raise exception 'FAIL 6: %', v;
  end if;
  perform pg_temp.ok('PASS 6: 1 July, no event: ' || v);

  -- 7. The monthly race resuming mid-month (Zz176 Later ended 15 June in B): nothing
  select count(*) into m from public.competition_start_posts where unit_id in (ua, ub);
  n := public._competition_start_post_due('2001-06-16');
  if (select count(*) from public.competition_start_posts where unit_id in (ua, ub)) <> m
     or exists (select 1 from public.competition_start_posts where competition_id = mz and period_from = '2001-06-01') then
    raise exception 'FAIL 7: a mid-month resume posted';
  end if;
  perform pg_temp.ok('PASS 7: 16 June (B resumes after its event): no post');

  -- 8. A draft event: nothing
  n := public._competition_start_post_due('2001-09-11');
  if exists (select 1 from public.competition_start_posts where competition_id = e5) then
    raise exception 'FAIL 8: the draft posted';
  end if;
  perform pg_temp.ok('PASS 8: a draft event starting today: no post');

  -- 9. Missed runs: 2 days ago yes (real start_on), 3 days ago no
  n := public._competition_start_post_due('2001-10-10');
  select string_agg(p.start_on::text, ',') into v from public.competition_start_posts p where p.competition_id = e6;
  if v is distinct from '2001-10-08' or exists (select 1 from public.competition_start_posts where competition_id = e7) then
    raise exception 'FAIL 9: 2 days ago %, 3 days ago %', v,
      (select count(*) from public.competition_start_posts where competition_id = e7);
  end if;
  perform pg_temp.ok('PASS 9: run on 10 Oct: the 8 Oct start inserted with start_on 2001-10-08; the 7 Oct start not');

  -- 10. The feed: own unit only, never a draft
  perform pg_temp.v_as(u_a);
  select count(*), count(*) filter (where f.unit_id <> ua) into n, m from public.competition_start_posts_feed() f;
  select string_agg(f.kind || '/' || f.prize_places || '/' || coalesce(f.finale_on::text, '-'), ',' order by f.kind)
    into v from public.competition_start_posts_feed() f where f.id = pa or f.competition_id = mz and f.period_from = '2001-07-01';
  execute 'reset role';
  if n <> 3 or m <> 0 or v is distinct from 'event/2/2001-04-21,monthly/0/-' then
    raise exception 'FAIL 10: A sees % rows, % from another unit; %', n, m, v;
  end if;
  update public.competitions set status = 'draft' where id = e1;
  perform pg_temp.v_as(u_a);
  select count(*) into m from public.competition_start_posts_feed() f where f.competition_id = e1;
  execute 'reset role';
  update public.competitions set status = 'active' where id = e1;
  perform pg_temp.v_as(u_b);
  select count(*), count(*) filter (where f.unit_id <> ub)::text into n, w from public.competition_start_posts_feed() f;
  execute 'reset role';
  if m <> 0 or w <> '0' or n <> 3 then
    raise exception 'FAIL 10: draft rows %, B sees % rows, % from another unit', m, n, w;
  end if;
  perform pg_temp.ok('PASS 10: the feed: Zz176 A sees only A''s posts (event 2 places + finale, monthly 0), Zz176 B only B''s; a draft''s posts disappear');

  -- 11. Oss 'race_start'
  perform pg_temp.v_as(u_a);
  res := public.toggle_oss('race_start', pa);
  select count(*) into n from public.wall_reactions where target_type = 'race_start' and target_id = pa;   -- through the policy
  select count(*) into m from public.wall_reactions where target_type = 'race_start' and target_id = pb;
  begin
    perform public.toggle_oss('race_start', pb);
    v := 'accepted';
  exception when others then v := sqlerrm;
  end;
  begin
    perform public.toggle_oss('race_start', gen_random_uuid());
    w := 'accepted';
  exception when others then w := sqlerrm;
  end;
  execute 'reset role';
  if res is distinct from '{"count": 1, "reacted": true}'::jsonb or n <> 1 or v <> 'target not visible' or w <> 'target not visible' then
    raise exception 'FAIL 11: %, seen %, other unit: %, random: %', res, n, v, w;
  end if;
  perform pg_temp.v_as(u_a);
  res := public.toggle_oss('race_start', pa);
  execute 'reset role';
  if res is distinct from '{"count": 0, "reacted": false}'::jsonb then
    raise exception 'FAIL 11: un-Oss %', res;
  end if;
  perform pg_temp.ok('PASS 11: toggle_oss race_start on A''s post {count 1, reacted}, visible through the policy, un-Oss ok; B''s post and a random uuid: target not visible');

  -- 4. The 21st post reuses the least recently used line (all 20 used once,
  --    line 7 the longest ago)
  delete from public.competition_start_posts;
  select id into da from public.competition_divisions where competition_id = mz and unit_id = ua and audience = 'adult';
  insert into public.competition_start_posts (competition_id, division_id, unit_id, period_from, period_to, start_on, line_id, published_at)
  select mz, da, ua, ('1990-01-01'::date + l.id), ('1990-01-01'::date + l.id), ('1990-01-01'::date + l.id), l.id,
         '2000-01-01'::timestamptz + make_interval(days => (l.id + 13) % 20)
    from public.competition_start_lines l;
  n := public._competition_start_post_due('2001-11-20');
  select line_id::text into v from public.competition_start_posts where competition_id = e8;
  if n <> 1 or v <> '7' then
    raise exception 'FAIL 4: returned %, line %', n, v;
  end if;
  perform pg_temp.ok('PASS 4: 20 lines used once each, line 7 the longest ago: the 21st post got line 7');

  -- 12. Live dry run on the real data (no fixtures, no posts)
  delete from public.competition_start_posts;
  delete from public.competitions where id in (mz, e1, e2, e3, e5, e6, e7, e8);
  n := public._competition_start_post_due('2026-11-01');
  m := public._competition_start_post_due('2026-11-02');
  select string_agg(u.name || ' / ' || d.label || ' / ' || p.period_from || '..' || p.period_to || ' / line ' || l.id || ': ' || l.line,
                    ' ; ' order by u.name)
    into v
    from public.competition_start_posts p
    join public.units u on u.id = p.unit_id
    join public.competition_divisions d on d.id = p.division_id
    join public.competitions c on c.id = p.competition_id
    join public.competition_start_lines l on l.id = p.line_id
   where c.name = 'Christmas Cup 2026' and d.audience = 'adult';
  if n <> 0 or m <> 2 or (select count(*) from public.competition_start_posts) <> 2
     or (select count(*) from public.competition_start_posts p join public.competitions c on c.id = p.competition_id
          join public.competition_divisions d on d.id = p.division_id join public.units u on u.id = p.unit_id
          where c.name = 'Christmas Cup 2026' and d.audience = 'adult' and u.name in ('Neutral Bay', 'Camperdown')
            and p.start_on = '2026-11-02' and p.period_from = '2026-11-02' and p.period_to = '2026-12-18') <> 2 then
    raise exception 'FAIL 12: 1 Nov %, 2 Nov %: %', n, m, v;
  end if;
  perform pg_temp.ok('PASS 12: live: due(2026-11-01) = 0 (the Cup starts within 7 days in both units); due(2026-11-02) = 2: ' || v);
end $$;

select n, t from res176 order by n;

rollback;
