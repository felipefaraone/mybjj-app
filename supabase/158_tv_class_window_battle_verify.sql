-- 158_tv_class_window_battle_verify.sql
--
-- Run AFTER 158, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/158_tv_class_window_battle_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- An ACTIVE July 2031 challenge on the first two units (by name). Each scenario
-- has its own day, closed at the first unit with one-off classes only, so the
-- real timetable never interferes (class_exceptions values are cast to the
-- table's real column types):
--   Tue 15 Jul: Adults 18:00 (60)                    cases 1 to 3
--   Wed 16 Jul: Adults 18:00 (60), Adults 19:00 (60) case 4 and 8
--   Thu 17 Jul: Kids 17:00 (45), Adults 18:00 (60)    case 5
--   Fri 18 Jul: Kids 18:00 (60), Adults 18:00 (60)    case 6
--   Mon 14 Jul: nothing (closed)                      case 7

begin;

create function pg_temp.pl(p jsonb) returns text language sql immutable as $f$
  select string_agg(x ->> 'screen', ',' order by o) from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;
create function pg_temp.secs(p jsonb) returns int language sql immutable as $f$
  select sum((x ->> 'seconds')::int)::int from jsonb_array_elements(p -> 'playlist') x
$f$;

do $$
declare
  ua uuid; ub uuid; comp uuid; scr uuid;
  s_y uuid; s_x uuid; s_z uuid; s_h2 uuid;
  s_p uuid; s_n uuid; s_l uuid; s_h uuid; s_q uuid;
  p jsonb; v text; n int; bad text; ty jsonb; e jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'students' and column_name = 'created_at') then
    raise exception 'FAIL setup: students.created_at missing';
  end if;

  -- fixtures: the challenge, both units' boards
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz158 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz158 a adults'), (comp, ua, 'kids', 'zz158 a kids'),
    (comp, ub, 'adult', 'zz158 b adults'), (comp, ub, 'kids', 'zz158 b kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'social_post', 2, true);

  -- the days (closed at the first unit) and their one-off classes
  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a
   where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  select string_agg(a.attname, ', ') into bad
    from pg_attribute a
   where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attnotnull and not a.atthasdef and a.attidentity = '' and a.attgenerated = ''
     and a.attname not in ('unit_id', 'exception_date', 'kind', 'oneoff_time', 'oneoff_audience', 'oneoff_duration_minutes');
  if bad is not null then raise exception 'FAIL setup: class_exceptions has other required columns: %', bad; end if;
  bad := null;
  execute format(
    'insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience, oneoff_duration_minutes)
     select $1::text::%s, x.d::text::%s, x.kind::%s, x.t::%s, x.aud::%s, x.dur::%s
       from (values (''2031-07-14'', ''closed'', null::text, null::text, null::text),
                    (''2031-07-15'', ''closed'', null, null, null), (''2031-07-15'', ''oneoff'', ''18:00'', ''Adults'', ''60''),
                    (''2031-07-16'', ''closed'', null, null, null), (''2031-07-16'', ''oneoff'', ''18:00'', ''Adults'', ''60''),
                    (''2031-07-16'', ''oneoff'', ''19:00'', ''Adults'', ''60''),
                    (''2031-07-17'', ''closed'', null, null, null), (''2031-07-17'', ''oneoff'', ''17:00'', ''Kids'', ''45''),
                    (''2031-07-17'', ''oneoff'', ''18:00'', ''Adults'', ''60''),
                    (''2031-07-18'', ''closed'', null, null, null), (''2031-07-18'', ''oneoff'', ''18:00'', ''Kids'', ''60''),
                    (''2031-07-18'', ''oneoff'', ''18:00'', ''Adults'', ''60'')) x(d, kind, t, aud, dur)',
    ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind', ty ->> 'oneoff_time',
    ty ->> 'oneoff_audience', ty ->> 'oneoff_duration_minutes')
  using ua;
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz158 tv', ua, encode(sha256('zz158-a'::bytea), 'hex'), true) returning id into scr;

  -- people on the lists (one-off classes: class_id null, the class time, the unit)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, photo_url)
    values ('Zz158 Yan Young','Yan','Young','adult',ua,true,'ok','blue',2,'zz158/yan.jpg') returning id into s_y;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, photo_url)
    values ('Zz158 Xia Xu','Xia','Xu','kids',ua,true,'ok','white',1,'zz158/xia.jpg') returning id into s_x;     -- a minor
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz158 Zed Zane','Zed','Zane','adult',ua,true,'ok','purple') returning id into s_z;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, leaderboard_hidden)
    values ('Zz158 Hal Hidden','Hal','Hidden','adult',ua,true,'ok',true) returning id into s_h2;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
  select x.sid, null, x.d, x.t, 'alev', x.st, 1.00, ua
    from (values (s_y, date '2031-07-15', '18:00', 'going'),
                 (s_x, date '2031-07-16', '18:00', 'present'), (s_x, date '2031-07-16', '19:00', 'going'),
                 (s_z, date '2031-07-16', '19:00', 'going'), (s_h2, date '2031-07-16', '19:00', 'going'),
                 (s_y, date '2031-07-17', '18:00', 'going'),
                 (s_y, date '2031-07-18', '18:00', 'going'), (s_z, date '2031-07-18', '18:00', 'going')) x(sid, d, t, st);

  -- 1. 2 PM, next class 6 PM: far, the list opens at 5:30 PM, no Up next, no names
  p := public._tv_payload(scr, '2031-07-15', '14:00');
  if p -> 'next_class' ->> 'state' is distinct from 'far' or p -> 'next_class' ->> 'opens_at' <> '17:30'
     or p -> 'next_class' ->> 'time' <> '18:00' or p -> 'up_next' <> '[]'::jsonb
     or p -> 'next_class' -> 'going' <> '[]'::jsonb or (p -> 'next_class' ->> 'on_the_way')::int <> 1
     or pg_temp.pl(p) like '%up_next%' then
    raise exception 'FAIL 1: % / up_next %', p -> 'next_class', p -> 'up_next';
  end if;
  raise notice 'PASS 1: 2 PM: next_class far, opens_at 17:30, up_next [], no names (1 on the way counted)';

  -- 2. 5:45 PM: the window, Up next first
  p := public._tv_payload(scr, '2031-07-15', '17:45');
  if p -> 'next_class' ->> 'state' is distinct from 'window' or jsonb_array_length(p -> 'up_next') <> 1
     or p -> 'up_next' -> 0 ->> 'audience' <> 'Adults' or p -> 'up_next' -> 0 ->> 'starts_at' <> '18:00'
     or p -> 'up_next' -> 0 -> 'people' -> 0 ->> 'name' <> 'Yan Young'
     or p -> 'up_next' -> 0 -> 'people' -> 0 ->> 'status' <> 'on_the_way'
     or p -> 'up_next' -> 0 -> 'people' -> 0 ->> 'belt' <> 'blue'
     or pg_temp.pl(p) not like 'up_next_adult,race_adults%' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 2: % / % / % (% s)', p -> 'next_class' ->> 'state', p -> 'up_next', pg_temp.pl(p), pg_temp.secs(p);
  end if;
  raise notice 'PASS 2: 5:45 PM: window, Up next block (Yan Young on the way, blue), playlist % (90 s)', pg_temp.pl(p);

  -- 3. 6:20 PM, the class running: on, no Up next
  p := public._tv_payload(scr, '2031-07-15', '18:20');
  if p -> 'next_class' ->> 'state' is distinct from 'on' or p -> 'next_class' ->> 'time' <> '18:00'
     or p -> 'up_next' <> '[]'::jsonb or pg_temp.pl(p) like '%up_next%' then
    raise exception 'FAIL 3: % / %', p -> 'next_class', p -> 'up_next';
  end if;
  raise notice 'PASS 3: 6:20 PM: state on (18:00), up_next []';

  -- 4. back to back 6 and 7 PM Adults, 6:45 PM: Up next is 7 PM; present at 6, going at 7 = here
  p := public._tv_payload(scr, '2031-07-16', '18:45');
  select string_agg((x ->> 'name') || ':' || (x ->> 'status'), ', ' order by o) into v
    from jsonb_array_elements(p -> 'up_next' -> 0 -> 'people') with ordinality t(x, o);
  if jsonb_array_length(p -> 'up_next') <> 1 or p -> 'up_next' -> 0 ->> 'time' <> '19:00'
     or v is distinct from 'Xia X.:here, Zed Zane:on_the_way'
     or (p -> 'up_next' -> 0 ->> 'here')::int <> 1 or (p -> 'up_next' -> 0 ->> 'on_the_way')::int <> 1
     or p -> 'next_class' ->> 'state' <> 'window' or p -> 'next_class' ->> 'time' <> '19:00'
     or (p -> 'next_class' ->> 'here')::int <> 1 then
    raise exception 'FAIL 4: % / %', p -> 'up_next', p -> 'next_class';
  end if;
  raise notice 'PASS 4: 6:45 PM: Up next 19:00: %', v;

  -- 5. Kids 5:00 to 5:45 running, Adults 6:00: at 5:35 kids only and the adult window held; at 5:50 Up next adults
  p := public._tv_payload(scr, '2031-07-17', '17:35');
  select string_agg(x, ',') into bad from unnest(string_to_array(pg_temp.pl(p), ',')) x
   where x not in ('race_kids', 'chase_kids', 'rules', 'battle_kids');
  if bad is not null or p -> 'up_next' <> '[]'::jsonb or p -> 'next_class' ->> 'state' <> 'on'
     or p -> 'next_class' ->> 'audience' <> 'Kids' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 5: 17:35 % (stray %) up_next %', pg_temp.pl(p), bad, p -> 'up_next';
  end if;
  v := pg_temp.pl(p);
  p := public._tv_payload(scr, '2031-07-17', '17:50');
  if jsonb_array_length(p -> 'up_next') <> 1 or p -> 'up_next' -> 0 ->> 'audience' <> 'Adults'
     or pg_temp.pl(p) not like 'up_next_adult,%' or pg_temp.pl(p) like '%kids%' then
    raise exception 'FAIL 5: 17:50 % / %', p -> 'up_next', pg_temp.pl(p);
  end if;
  raise notice 'PASS 5: 5:35 PM kids only (%), adult window held; 5:50 PM Up next adults (%)', v, pg_temp.pl(p);

  -- 6. Kids and Adults at the same start: two blocks, everything
  p := public._tv_payload(scr, '2031-07-18', '17:45');
  select string_agg(x ->> 'audience', ',' order by o) into v from jsonb_array_elements(p -> 'up_next') with ordinality t(x, o);
  if v is distinct from 'Adults,Kids' or pg_temp.pl(p) not like 'up_next_adult,up_next_kids,race_adults,race_kids%'
     or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 6: % / %', v, pg_temp.pl(p);
  end if;
  raise notice 'PASS 6: same start: blocks %, playlist % (90 s)', v, pg_temp.pl(p);

  -- 7. battle: points per member over the base
  --   first unit adults: P trained before (base), N joined in the period and
  --   trained (base), L lapsed and back (points, not base), H hidden trained
  --   before (base, points). second unit adults: Q trained before (base).
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz158 Pre P','Pre','P','adult',ua,true,'ok') returning id into s_p;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, created_at)
    values ('Zz158 New N','New','N','adult',ua,true,'ok', timestamptz '2031-07-05 10:00+10') returning id into s_n;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, created_at)
    values ('Zz158 Lap L','Lap','L','adult',ua,true,'ok', timestamptz '2030-01-01 10:00+10') returning id into s_l;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, leaderboard_hidden)
    values ('Zz158 Hid H','Hid','H','adult',ua,true,'ok',true) returning id into s_h;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz158 Que Q','Que','Q','adult',ub,true,'ok') returning id into s_q;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, x.d, '07:00', 'alev', 'present', 1.00, 'gi', x.u
    from (values (s_p, date '2031-06-10', ua), (s_p, date '2031-07-02', ua),
                 (s_n, date '2031-07-06', ua),
                 (s_l, date '2031-03-01', ua), (s_l, date '2031-07-03', ua), (s_l, date '2031-07-04', ua),
                 (s_h, date '2031-06-15', ua), (s_h, date '2031-07-02', ua),
                 (s_q, date '2031-06-20', ub), (s_q, date '2031-07-02', ub), (s_q, date '2031-07-03', ub)) x(sid, d, u);
  p := public._tv_payload(scr, '2031-07-14', '10:00');
  select x into e from jsonb_array_elements(p -> 'battle' -> 'adult') x where (x ->> 'here')::boolean;
  -- the first unit's adults: P 1 + N 1 + L 2 + H 1 + Yan, Zed (going only, 0) = 5 points; base 3
  if (e ->> 'points')::numeric <> 5 or (e ->> 'base')::int <> 3 or (e ->> 'per_member')::numeric <> 1.67
     or not (e ? 'avg' and e ? 'active' and e ? 'classes' and e ? 'unit') then
    raise exception 'FAIL 7: first unit %', e;
  end if;
  select x into e from jsonb_array_elements(p -> 'battle' -> 'adult') x where not (x ->> 'here')::boolean;
  if (e ->> 'points')::numeric <> 2 or (e ->> 'base')::int <> 1 or (e ->> 'per_member')::numeric <> 2.00 then
    raise exception 'FAIL 7: second unit %', e;
  end if;
  if pg_temp.pl(p) not like '%,battle%' then raise exception 'FAIL 7: both bases > 0 but no battle: %', pg_temp.pl(p); end if;
  raise notice 'PASS 7: battle first unit 5 points / base 3 = 1.67, second 2 / 1 = 2.00; battle offered (both bases > 0)';

  -- 8. privacy on Up next: the hidden member never listed; the minor initial only, no photo; belts
  insert into public.competition_awards (student_id, award_key, award_date) values (s_y, 'social_post', '2031-07-12');
  p := public._tv_payload(scr, '2031-07-16', '18:45');
  if p::text like '%Hal Hidden%' or p::text like '%Hal H.%' then raise exception 'FAIL 8: hidden member on the TV'; end if;
  select x into e from jsonb_array_elements(p -> 'up_next' -> 0 -> 'people') x where x ->> 'name' = 'Xia X.';
  if e is null or (e ->> 'minor')::boolean is not true or e ->> 'photo_path' is not null or p::text like '%xia.jpg%'
     or e ->> 'belt' <> 'white' or (e ->> 'degree')::int <> 1 then
    raise exception 'FAIL 8: minor %', e;
  end if;
  -- feed items carry belts (A5)
  select x into e from jsonb_array_elements(p -> 'feed') x where x ->> 'name' = 'Yan Young';
  if e is null or e ->> 'belt' <> 'blue' or (e ->> 'degree')::int <> 2 or not (e ? 'minor')
     or exists (select 1 from jsonb_array_elements(p -> 'feed') x where not (x ? 'belt' and x ? 'degree' and x ? 'minor')) then
    raise exception 'FAIL 8: feed item %', e;
  end if;
  raise notice 'PASS 8: hidden member never on Up next; minor % (no photo, white 1); feed items carry belt and degree', e ->> 'name';
end $$;

rollback;
