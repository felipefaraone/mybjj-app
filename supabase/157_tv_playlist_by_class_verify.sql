-- 157_tv_playlist_by_class_verify.sql
--
-- Run AFTER 157, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/157_tv_playlist_by_class_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic people, an ACTIVE July 2031 challenge on the first two units (by
-- name), and Tue 15 Jul 2031 closed at both units with one-off classes only (so
-- real timetables never interfere): Kids 16:00, Adults 18:00, All 20:00, and
-- Kids + Adults together at 21:30. Screen "battle" = show_battle true (the
-- Neutral Bay setting), "no battle" = false (Camperdown).

begin;

create function pg_temp.pl(p jsonb) returns text language sql immutable as $f$
  select string_agg(x ->> 'screen', ',' order by o) from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;
create function pg_temp.secs(p jsonb) returns int language sql immutable as $f$
  select sum((x ->> 'seconds')::int)::int from jsonb_array_elements(p -> 'playlist') x
$f$;

do $$
declare
  ua uuid; ub uuid; comp uuid; s_bat uuid; s_nob uuid;
  sa uuid; sk uuid; sb uuid; sl uuid;
  p jsonb; v text; n int; t time; bad text;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;

  -- 1. the per screen setting and the migration's data
  if (select c.column_default from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = 'tv_screens' and c.column_name = 'show_battle') is distinct from 'false' then
    raise exception 'FAIL 1: show_battle missing or not default false';
  end if;
  select count(*) into n from public.tv_screens
   where (unit_id = 'c851cef5-d5b7-4d5b-b400-11f6ca760970' and show_battle is false)
      or (unit_id = '3654625a-a157-4392-966a-7be69d4b0c6e' and show_battle is true);
  if n <> 0 then raise exception 'FAIL 1: % screen(s) with the wrong battle setting (NB true, CD false)', n; end if;
  raise notice 'PASS 1: tv_screens.show_battle default false; Neutral Bay screens true, Camperdown screens false';

  -- fixtures
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz157 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz157 a adults'), (comp, ua, 'kids', 'zz157 a kids'),
    (comp, ub, 'adult', 'zz157 b adults'), (comp, ub, 'kids', 'zz157 b kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'social_post', 2, true), (comp, 'class_challenge', 3, true);
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz157 Ann A','Ann','A','adult',ua,true,'ok','blue') returning id into sa;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz157 Kit K','Kit','K','kids',ua,true,'ok','grey') returning id into sk;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz157 Bob B','Bob','B','adult',ub,true,'ok','white') returning id into sb;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz157 Lou L','Lou','L','kids',ub,true,'ok','yellow') returning id into sl;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, x.d, '18:00', 'alev', 'present', 1.00, 'gi', x.u
    from (values (sa, date '2031-07-01', ua), (sa, date '2031-07-02', ua), (sk, date '2031-07-01', ua),
                 (sb, date '2031-07-01', ub), (sl, date '2031-07-01', ub)) x(sid, d, u);
  insert into public.competition_awards (student_id, award_key, award_date) values
    (sa, 'social_post', '2031-07-12'), (sk, 'social_post', '2031-07-13');
  insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience, oneoff_duration_minutes)
  select u.id, date '2031-07-15', x.kind, x.t, x.aud, x.dur
    from (values (ua), (ub)) u(id)
   cross join (values ('closed', null, null, null::int),
                      ('oneoff', '16:00', 'Kids', 45), ('oneoff', '18:00', 'Adults', 60), ('oneoff', '20:00', 'All', 60),
                      ('oneoff', '21:30', 'Kids', 30), ('oneoff', '21:30', 'Adults', 30)) x(kind, t, aud, dur);
  insert into public.tv_screens (name, unit_id, token_hash, show_battle) values
    ('zz157 battle', ua, encode(sha256('zz157-a'::bytea), 'hex'), true) returning id into s_bat;
  insert into public.tv_screens (name, unit_id, token_hash, show_battle) values
    ('zz157 no battle', ub, encode(sha256('zz157-b'::bytea), 'hex'), false) returning id into s_nob;

  -- 2. no class on (12:00, the next is 16:00): everything, as before
  p := public._tv_payload(s_bat, '2031-07-15', '12:00');
  v := pg_temp.pl(p);
  if v not like 'race_adults,race_kids,%' or v not like '%battle%' or v not like '%feed%' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 2: % (% s)', v, pg_temp.secs(p);
  end if;
  raise notice 'PASS 2: no class on -> everything: % (90 s)', v;

  -- 3. Kids class within 30 minutes at the battle screen: kids screens + kids battle
  p := public._tv_payload(s_bat, '2031-07-15', '15:35');
  v := pg_temp.pl(p);
  select string_agg(x, ',') into bad from unnest(string_to_array(v, ',')) x
   where x not in ('race_kids', 'chase_kids', 'rules', 'battle_kids');
  if bad is not null or v not like 'race_kids%' or v not like '%battle_kids%' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 3: % (stray %; % s)', v, bad, pg_temp.secs(p);
  end if;
  raise notice 'PASS 3: Kids class (starts in 25 min), battle screen: % (90 s)', v;

  -- 4. Kids class running at the no-battle screen: kids screens, no battle
  p := public._tv_payload(s_nob, '2031-07-15', '16:20');
  v := pg_temp.pl(p);
  select string_agg(x, ',') into bad from unnest(string_to_array(v, ',')) x
   where x not in ('race_kids', 'chase_kids', 'rules');
  if bad is not null or v not like 'race_kids%' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 4: % (stray %)', v, bad;
  end if;
  raise notice 'PASS 4: Kids class running, no-battle screen: % (90 s)', v;

  -- 5. Adults class running: adult screens + adult battle, adult feed only
  p := public._tv_payload(s_bat, '2031-07-15', '18:30');
  v := pg_temp.pl(p);
  select string_agg(x, ',') into bad from unnest(string_to_array(v, ',')) x
   where x not in ('race_adults', 'chase_adults', 'rules', 'feed_adults', 'battle_adults', 'gi_nogi');
  if bad is not null or v not like 'race_adults%' or v not like '%feed_adults%' or v not like '%battle_adults%'
     or v not like '%gi_nogi%' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 5: % (stray %)', v, bad;
  end if;
  raise notice 'PASS 5: Adults class running, battle screen: % (90 s)', v;

  -- 6. All class, and Kids + Adults at once: everything
  p := public._tv_payload(s_bat, '2031-07-15', '20:10');
  v := pg_temp.pl(p);
  if v not like 'race_adults,race_kids,%' or v not like '%,battle%' or v ~ 'battle_(adults|kids)' or pg_temp.secs(p) <> 90 then
    raise exception 'FAIL 6: All class: %', v;
  end if;
  p := public._tv_payload(s_bat, '2031-07-15', '21:15');
  if pg_temp.pl(p) not like 'race_adults,race_kids,%' then raise exception 'FAIL 6: Kids + Adults at once: %', pg_temp.pl(p); end if;
  raise notice 'PASS 6: All class -> everything (%); Kids and Adults together -> everything', v;

  -- 7. the no-battle screen never has a battle, and every playlist sums to 90
  for t in select unnest(array['12:00', '15:35', '16:20', '18:30', '20:10', '21:15', '23:59']::time[]) loop
    p := public._tv_payload(s_nob, '2031-07-15', t);
    if pg_temp.pl(p) like '%battle%' or pg_temp.secs(p) <> 90 then
      raise exception 'FAIL 7: no-battle screen at %: % (% s)', t, pg_temp.pl(p), pg_temp.secs(p);
    end if;
    p := public._tv_payload(s_bat, '2031-07-15', t);
    if pg_temp.secs(p) <> 90 then raise exception 'FAIL 7: battle screen at %: % s', t, pg_temp.secs(p); end if;
  end loop;
  raise notice 'PASS 7: the no-battle screen never shows a battle; every playlist sums to 90 s';
end $$;

rollback;
