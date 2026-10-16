-- 160_tv_one_audience_per_screen_verify.sql
--
-- Run AFTER 160, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/160_tv_one_audience_per_screen_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- An ACTIVE July 2031 challenge on the first two units (by name). Each case has
-- its own day, closed at the first unit (one-off classes only), so the real
-- timetable never interferes (class_exceptions values cast to the real types):
--   Mon 14 Jul: nothing                  cases 1 and 2 (everything)
--   Tue 15 Jul: Kids 18:00 (60)          case 3 (kids focus)
--   Wed 16 Jul: Adults 18:00 (60)        case 4 (adults focus)
--   Mon 21 Jul: nothing                  case 5 (feed by audience)
--   Sun  3 Aug: nothing                  case 6 (last month's results, monthly)

begin;

create function pg_temp.pl(p jsonb) returns text language sql immutable as $f$
  select string_agg(x ->> 'screen', ',' order by o) from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o)
$f$;
create function pg_temp.secs(p jsonb) returns int language sql immutable as $f$
  select sum((x ->> 'seconds')::int)::int from jsonb_array_elements(p -> 'playlist') x
$f$;
-- no combined screen, 90 s, and every audience screen has its data
create function pg_temp.bad(p jsonb, p_today date) returns text language sql immutable as $f$
  select string_agg(s, ', ') from (
    select 'combined ' || (x ->> 'screen') as s from jsonb_array_elements(p -> 'playlist') x
     where x ->> 'screen' in ('battle', 'feed', 'last_results')
    union all select 'seconds ' || pg_temp.secs(p) where pg_temp.secs(p) <> 90
    union all select 'feed_' || a || ' without items'
      from unnest(array['adults', 'kids']) a
     where pg_temp.pl(p) ~ ('(^|,)feed_' || a || '(,|$)')
       and not exists (select 1 from jsonb_array_elements(p -> 'feed') f
                        where f ->> 'audience' = case a when 'adults' then 'adult' else 'kids' end
                          and (f ->> 'date')::date >= p_today - 6)
    union all select 'last_results_' || a || ' without rows'
      from unnest(array['adult', 'kids']) a
     where pg_temp.pl(p) ~ ('(^|,)last_results_' || a || '(,|$)')
       and jsonb_array_length(coalesce(p -> 'last_results' -> a, '[]'::jsonb)) = 0
    union all select 'battle_' || a || ' without a base at both units'
      from unnest(array['adults', 'kids']) a
     where pg_temp.pl(p) ~ ('(^|,)battle_' || a || '(,|$)')
       and (jsonb_array_length(coalesce(p -> 'battle' -> case a when 'adults' then 'adult' else 'kids' end, '[]'::jsonb)) < 2
            or exists (select 1 from jsonb_array_elements(p -> 'battle' -> case a when 'adults' then 'adult' else 'kids' end) b
                        where coalesce((b ->> 'base')::int, 0) <= 0))
  ) z
$f$;

do $$
declare
  ua uuid; ub uuid; comp uuid; scr uuid; ty jsonb; bad text; v text;
  s_a uuid; s_k uuid; s_b uuid; s_kb uuid;
  p jsonb;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz160 Cup', 'event', '2031-07-01', '2031-07-31', null, 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz160 a adults'), (comp, ua, 'kids', 'zz160 a kids'),
    (comp, ub, 'adult', 'zz160 b adults'), (comp, ub, 'kids', 'zz160 b kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp, 'class_attended', 1, true), (comp, 'social_post', 2, true);

  select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
    from pg_attribute a
   where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
  select string_agg(a.attname, ', ') into bad
    from pg_attribute a
   where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attnotnull and not a.atthasdef and a.attidentity = '' and a.attgenerated = ''
     and a.attname not in ('unit_id', 'exception_date', 'kind', 'oneoff_time', 'oneoff_audience', 'oneoff_duration_minutes');
  if bad is not null then raise exception 'FAIL setup: class_exceptions has other required columns: %', bad; end if;
  execute format(
    'insert into public.class_exceptions (unit_id, exception_date, kind, oneoff_time, oneoff_audience, oneoff_duration_minutes)
     select $1::text::%s, x.d::text::%s, x.kind::%s, x.t::%s, x.aud::%s, x.dur::%s
       from (values (''2031-07-14'', ''closed'', null::text, null::text, null::text),
                    (''2031-07-15'', ''closed'', null, null, null), (''2031-07-15'', ''oneoff'', ''18:00'', ''Kids'', ''60''),
                    (''2031-07-16'', ''closed'', null, null, null), (''2031-07-16'', ''oneoff'', ''18:00'', ''Adults'', ''60''),
                    (''2031-07-21'', ''closed'', null, null, null),
                    (''2031-08-03'', ''closed'', null, null, null)) x(d, kind, t, aud, dur)',
    ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind', ty ->> 'oneoff_time',
    ty ->> 'oneoff_audience', ty ->> 'oneoff_duration_minutes')
  using ua;
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz160 tv', ua, encode(sha256('zz160-a'::bytea), 'hex'), true) returning id into scr;

  -- people: adults and kids at both units; the second unit's kid has no base yet
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz160 Ann A','Ann','A','adult',ua,true,'ok','blue') returning id into s_a;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz160 Kit K','Kit','K','kids',ua,true,'ok','grey') returning id into s_k;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz160 Bob B','Bob','B','adult',ub,true,'ok','white') returning id into s_b;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz160 Kai B','Kai','B','kids',ub,true,'ok','yellow') returning id into s_kb;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, x.d, '07:00', 'alev', 'present', 1.00, 'gi', x.u
    from (values (s_a, date '2031-06-10', ua), (s_a, date '2031-07-02', ua), (s_a, date '2031-07-03', ua),
                 (s_k, date '2031-06-12', ua), (s_k, date '2031-07-02', ua),
                 (s_b, date '2031-06-20', ub), (s_b, date '2031-07-02', ub),
                 (s_kb, date '2031-07-02', ub)) x(sid, d, u);
  insert into public.competition_awards (student_id, award_key, award_date) values
    (s_a, 'social_post', '2031-07-12'), (s_k, 'social_post', '2031-07-13');

  -- 1. everything: no combined screen; adults battle, both feeds; no kids battle yet (no base at the second unit)
  p := public._tv_payload(scr, '2031-07-14', '10:00');
  bad := pg_temp.bad(p, '2031-07-14'); v := pg_temp.pl(p);
  if bad is not null or v !~ '(^|,)battle_adults(,|$)' or v ~ 'battle_kids' or v !~ 'feed_adults' or v !~ 'feed_kids' then
    raise exception 'FAIL 1: % (%)', v, bad;
  end if;
  raise notice 'PASS 1: everything: % (90 s, one audience per screen; no kids battle: no base at the second unit)', v;

  -- 2. the second unit's kid trained before: the kids battle appears, on its own screen
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s_kb, null, '2031-06-25', '07:00', 'alev', 'present', 1.00, 'gi', ub);
  p := public._tv_payload(scr, '2031-07-14', '10:00');
  bad := pg_temp.bad(p, '2031-07-14'); v := pg_temp.pl(p);
  if bad is not null or v !~ 'battle_kids' or v !~ 'battle_adults' then raise exception 'FAIL 2: % (%)', v, bad; end if;
  raise notice 'PASS 2: both bases: battle_adults and battle_kids as separate screens: %', v;

  -- 3. kids focus
  p := public._tv_payload(scr, '2031-07-15', '18:20');
  bad := pg_temp.bad(p, '2031-07-15'); v := pg_temp.pl(p);
  select string_agg(x, ',') into bad from unnest(string_to_array(v, ',')) x
   where x not in ('race_kids', 'chase_kids', 'rules', 'battle_kids', 'up_next_kids');
  if pg_temp.bad(p, '2031-07-15') is not null or bad is not null then raise exception 'FAIL 3: % (%)', v, coalesce(bad, pg_temp.bad(p, '2031-07-15')); end if;
  raise notice 'PASS 3: kids focus: % (90 s)', v;

  -- 4. adults focus
  p := public._tv_payload(scr, '2031-07-16', '18:20');
  v := pg_temp.pl(p);
  select string_agg(x, ',') into bad from unnest(string_to_array(v, ',')) x
   where x not in ('race_adults', 'chase_adults', 'rules', 'feed_adults', 'battle_adults', 'gi_nogi', 'up_next_adult');
  if pg_temp.bad(p, '2031-07-16') is not null or bad is not null then raise exception 'FAIL 4: % (%)', v, coalesce(bad, pg_temp.bad(p, '2031-07-16')); end if;
  raise notice 'PASS 4: adults focus: % (90 s)', v;

  -- 5. Latest points per audience: only the audience with items in the last 7 days
  insert into public.competition_awards (student_id, award_key, award_date) values (s_a, 'social_post', '2031-07-20');
  p := public._tv_payload(scr, '2031-07-21', '10:00');
  bad := pg_temp.bad(p, '2031-07-21'); v := pg_temp.pl(p);
  if bad is not null or v !~ 'feed_adults' or v ~ 'feed_kids' then raise exception 'FAIL 5: % (%)', v, bad; end if;
  raise notice 'PASS 5: adult item 1 day ago, kids item 8 days ago: feed_adults only (%)', v;

  -- 6. last month's results per audience (the monthly race, first 7 days)
  p := public._tv_payload(scr, '2031-08-03', '10:00');
  bad := pg_temp.bad(p, '2031-08-03'); v := pg_temp.pl(p);
  if p -> 'competition' ->> 'kind' <> 'monthly' then raise exception 'FAIL 6: not the monthly race: %', p -> 'competition'; end if;
  if bad is not null
     or (v ~ 'last_results_adult') <> (jsonb_array_length(coalesce(p -> 'last_results' -> 'adult', '[]'::jsonb)) > 0)
     or (v ~ 'last_results_kids') <> (jsonb_array_length(coalesce(p -> 'last_results' -> 'kids', '[]'::jsonb)) > 0)
     or v !~ 'last_results_adult' or v !~ 'last_results_kids' then
    raise exception 'FAIL 6: % (%) last %', v, bad, p -> 'last_results';
  end if;
  raise notice 'PASS 6: monthly, 3 Aug: last_results_adult and last_results_kids as separate screens: %', v;
end $$;

rollback;
