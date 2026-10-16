-- 155_tv_board_verify.sql
--
-- Run AFTER 155, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/155_tv_board_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic people and a synthetic DRAFT challenge "Zz155 Cup" in July 2031 on
-- the first unit (by name); the dates are pinned through _tv_payload.

begin;

do $$
declare
  ua uuid; cls uuid; comp uuid; scr uuid; scr_off uuid;
  s_ann uuid; s_ben uuid; s_cal uuid; s_hid uuid; s_kit uuid; s_lou uuid;
  p jsonb; v text; n int; tok text := encode(sha256('zz155-token-active'::bytea), 'hex');
  tok_off text := encode(sha256('zz155-token-inactive'::bytea), 'hex');
  ty jsonb;   -- class_exceptions column -> its real type (created outside the repo)
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'FAIL setup: needs a unit'; end if;

  -- 1. privileges: only service_role runs tv_payload; internals closed; table closed
  if has_function_privilege('anon', 'public.tv_payload(text)', 'execute')
     or has_function_privilege('authenticated', 'public.tv_payload(text)', 'execute')
     or not has_function_privilege('service_role', 'public.tv_payload(text)', 'execute') then
    raise exception 'FAIL 1: tv_payload execute grants wrong';
  end if;
  if has_function_privilege('authenticated', 'public._tv_payload(uuid, date, time)', 'execute')
     or has_function_privilege('anon', 'public._tv_payload(uuid, date, time)', 'execute')
     or has_function_privilege('service_role', 'public._tv_payload(uuid, date, time)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_award_counts(uuid, uuid, date)', 'execute') then
    raise exception 'FAIL 1: an internal function is executable by a client role';
  end if;
  if has_table_privilege('anon', 'public.tv_screens', 'select')
     or has_table_privilege('authenticated', 'public.tv_screens', 'select')
     or not (select c.relrowsecurity from pg_class c where c.oid = 'public.tv_screens'::regclass) then
    raise exception 'FAIL 1: tv_screens readable by clients or RLS off';
  end if;
  raise notice 'PASS 1: tv_payload executable only by service_role; internals and tv_screens closed to anon / authenticated (RLS on)';

  -- 2. tokens: unknown, malformed, inactive -> null; active -> payload + last_seen_at
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz155 tv', ua, tok) returning id into scr;
  insert into public.tv_screens (name, unit_id, token_hash, active) values ('zz155 off', ua, tok_off, false) returning id into scr_off;
  if public.tv_payload(encode(sha256('zz155-nope'::bytea), 'hex')) is not null
     or public.tv_payload('not-a-hash') is not null
     or public.tv_payload(null) is not null
     or public.tv_payload(tok_off) is not null then
    raise exception 'FAIL 2: unknown / malformed / inactive token returned a payload';
  end if;
  p := public.tv_payload(tok);
  if p is null
     or (select last_seen_at from public.tv_screens where id = scr) is null
     or (select last_seen_at from public.tv_screens where id = scr_off) is not null then
    raise exception 'FAIL 2: active token gave no payload or last_seen_at not stamped';
  end if;
  raise notice 'PASS 2: unknown, malformed and inactive tokens -> null; the active one -> payload, last_seen_at stamped';

  -- fixtures: a DRAFT July 2031 challenge, people, a class on Tuesdays 23:30
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes, theme)
    values ('Zz155 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'draft',
            '[{"place":1,"label":"1st"},{"place":2,"label":"2nd"},{"place":3,"label":"3rd"}]', '{"style":"christmas"}')
    returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz155 adults'), (comp, ua, 'kids', 'zz155 kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values
    (comp,'class_attended',1,true),(comp,'class_challenge',3,true),(comp,'best_attitude',1,false),
    (comp,'social_post',2,true),(comp,'referral_trial',3,true),(comp,'referral_conversion',5,true);
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, photo_url)
    values ('Zz155 Ann Alpha','Ann','Alpha','adult',ua,true,'ok','zz155/ann.jpg') returning id into s_ann;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, photo_url)
    values ('Zz155 Ben Beta','Ben','Beta','adult',ua,true,'ok','zz155/ben.jpg') returning id into s_ben;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, prize_eligible)
    values ('Zz155 Cal Coach','Cal','Coach','adult',ua,true,'ok',false) returning id into s_cal;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, leaderboard_hidden, photo_url)
    values ('Zz155 Hid Den','Hid','Den','adult',ua,true,'ok',true,'zz155/hid.jpg') returning id into s_hid;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, photo_url)
    values ('Zz155 Kit Kid','Kit','Kid','kids',ua,true,'ok','zz155/kit.jpg') returning id into s_kit;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz155 Lou Low','Lou','Low','kids',ua,true,'ok') returning id into s_lou;
  insert into public.classes (unit_id, day_of_week, time, type, duration_minutes, audience, active, uniform, level, legacy_id)
    values (ua, 2, '23:30', 'alev', 30, 'Adults', true, 'Gi', 'All Levels', 'zz155') returning id into cls;

  -- points: Ann 3 gi classes + a challenge she was present for = 6; Cal (staff)
  -- 5 no-gi = 5; Ben 2 no-gi + a challenge WITHOUT presence = 2; Hid (hidden) 7;
  -- Kit 2 + social post = 4; Lou 1.
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, x.cid, x.d, '18:00', 'alev', 'present', 1.00, x.m, ua
    from (values (s_ann, cls, date '2031-07-01', 'gi'), (s_ann, null::uuid, date '2031-07-02', 'gi'), (s_ann, null, date '2031-07-03', 'gi'),
                 (s_cal, null, date '2031-07-01', 'nogi'), (s_cal, null, date '2031-07-02', 'nogi'), (s_cal, null, date '2031-07-03', 'nogi'),
                 (s_cal, null, date '2031-07-04', 'nogi'), (s_cal, null, date '2031-07-05', 'nogi'),
                 (s_ben, null, date '2031-07-01', 'nogi'), (s_ben, null, date '2031-07-02', 'nogi'),
                 (s_hid, null, date '2031-07-01', 'gi'), (s_hid, null, date '2031-07-02', 'gi'), (s_hid, null, date '2031-07-03', 'gi'),
                 (s_hid, null, date '2031-07-04', 'gi'), (s_hid, null, date '2031-07-05', 'gi'), (s_hid, null, date '2031-07-06', 'gi'),
                 (s_hid, null, date '2031-07-07', 'gi'),
                 (s_kit, null, date '2031-07-01', 'gi'), (s_kit, null, date '2031-07-02', 'gi'),
                 (s_lou, null, date '2031-07-01', 'gi')) as x(sid, cid, d, m);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date) values
    (s_ann, 'class_challenge', '2031-07-01', cls, '2031-07-01'),
    (s_ben, 'class_challenge', '2031-07-10', cls, '2031-07-10');           -- no attendance: never counts
  insert into public.competition_awards (student_id, award_key, award_date) values
    (s_kit, 'social_post', '2031-07-12'), (s_hid, 'social_post', '2031-07-13');
  -- tonight's class (Tue 15 Jul 2031, 23:30): Ann going, Kit going, Hid going
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_ann, cls, '2031-07-15', '23:30', 'alev', 'going', 1.00, ua),
           (s_kit, cls, '2031-07-15', '23:30', 'alev', 'going', 1.00, ua),
           (s_hid, cls, '2031-07-15', '23:30', 'alev', 'going', 1.00, ua);

  -- 3. a draft never reaches the TV
  p := public._tv_payload(scr, '2031-07-15', '23:00');
  if p -> 'competition' ->> 'name' = 'Zz155 Cup' or p -> 'competition' ->> 'kind' is distinct from 'monthly' then
    raise exception 'FAIL 3: draft chosen: %', p -> 'competition';
  end if;
  raise notice 'PASS 3: draft challenge never chosen (monthly race shown: %)', p -> 'competition' ->> 'name';

  -- 4. active: before the start the monthly; once started the Cup, with its theme
  update public.competitions set status = 'active' where id = comp;
  p := public._tv_payload(scr, '2031-06-30', '12:00');
  if p -> 'competition' ->> 'kind' is distinct from 'monthly' then raise exception 'FAIL 4: before the start: %', p -> 'competition'; end if;
  p := public._tv_payload(scr, '2031-07-15', '23:00');
  if p -> 'competition' ->> 'name' is distinct from 'Zz155 Cup' or p -> 'competition' ->> 'phase' <> 'live'
     or p ->> 'theme' is distinct from 'christmas' or (p -> 'competition' ->> 'places')::int <> 3 then
    raise exception 'FAIL 4: once started: % theme %', p -> 'competition', p ->> 'theme';
  end if;
  raise notice 'PASS 4: before the start the monthly race; once started the Cup (live, 3 places, theme christmas)';

  -- 5. the hidden member appears nowhere (boards, feed, gi / no-gi, going)
  if p::text like '%Hid Den%' or p::text like '%hid.jpg%' then raise exception 'FAIL 5: hidden member on the TV'; end if;
  raise notice 'PASS 5: leaderboard_hidden member absent from the whole payload';

  -- 6. adults board: real positions, staff flagged, prize places skip staff, photo path
  select string_agg((e ->> 'rank') || ':' || (e ->> 'name') || ':' || (e ->> 'points') || ':' || coalesce(e ->> 'prize_rank', '-')
                    || ':' || (e ->> 'staff'), ' | ' order by (e ->> 'rank')::int)
    into v from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') e where e ->> 'name' like '%Alpha' or e ->> 'name' like '%Beta' or e ->> 'name' like '%Coach';
  -- Hid (hidden, 7) keeps rank 1 and prize 1: positions are never renumbered
  if v is distinct from '2:Ann Alpha:6.00:2:false | 3:Cal Coach:5.00:-:true | 4:Ben Beta:2.00:3:false' then
    raise exception 'FAIL 6: %', v;
  end if;
  if (select e ->> 'photo_path' from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') e where e ->> 'name' = 'Ann Alpha') is distinct from 'zz155/ann.jpg' then
    raise exception 'FAIL 6: adult photo path missing';
  end if;
  raise notice 'PASS 6: adults (rank:name:points:prize:staff) %', v;

  -- 7. kids: first name + last initial, never a photo
  select string_agg((e ->> 'name') || ':' || coalesce(e ->> 'photo_path', 'none'), ' | ' order by (e ->> 'rank')::int)
    into v from jsonb_array_elements(p -> 'boards' -> 'kids' -> 'rows') e where e ->> 'name' in ('Kit K.', 'Lou L.');
  if v is distinct from 'Kit K.:none | Lou L.:none' or p::text like '%kit.jpg%' then raise exception 'FAIL 7: %', v; end if;
  if (select x ->> 'photo_path' from jsonb_array_elements(p -> 'next_class' -> 'going') x where x ->> 'name' = 'Kit K.') is not null then
    raise exception 'FAIL 7: kid photo in the going list';
  end if;
  raise notice 'PASS 7: kids %; no kid photo anywhere', v;

  -- 8. an award without presence: absent from points and from the feed
  select string_agg((e ->> 'name') || ' ' || (e ->> 'key') || ' +' || (e ->> 'points'), ' | ' order by e ->> 'date' desc)
    into v from jsonb_array_elements(p -> 'feed') e where e ->> 'name' in ('Ann Alpha', 'Ben Beta', 'Kit K.');
  if v is distinct from 'Kit K. social_post +2 | Ann Alpha class_challenge +3' then raise exception 'FAIL 8: feed %', v; end if;
  if (select s.award_points from public._competition_scores(comp, null, null) s where s.student_id = s_ben) <> 0
     or (select s.award_points from public._competition_scores(comp, null, null) s where s.student_id = s_ann) <> 3 then
    raise exception 'FAIL 8: award points wrong';
  end if;
  if public._competition_award_counts(s_ben, cls, '2031-07-10') or not public._competition_award_counts(s_ann, cls, '2031-07-01')
     or not public._competition_award_counts(s_ann, null, null) then
    raise exception 'FAIL 8: predicate wrong';
  end if;
  raise notice 'PASS 8: award without presence counts nowhere; feed %', v;

  -- 9. chase, gi / no-gi, battle, next class
  if p -> 'chase' -> 'adult' ->> 'kind' is distinct from 'first' or p -> 'chase' -> 'adult' -> 'a' ->> 'name' <> 'Ann Alpha'
     or (p -> 'chase' -> 'adult' ->> 'place')::int <> 2
     or (p -> 'chase' -> 'adult' ->> 'gap')::numeric <> 1 or p -> 'chase' -> 'adult' -> 'a' ? 'sid' then
    raise exception 'FAIL 9: chase %', p -> 'chase' -> 'adult';
  end if;
  if p -> 'gi_nogi' -> 'gi' -> 0 ->> 'name' is distinct from 'Ann Alpha' or p -> 'gi_nogi' -> 'nogi' -> 0 ->> 'name' is distinct from 'Cal Coach' then
    raise exception 'FAIL 9: gi / no-gi %', p -> 'gi_nogi';
  end if;
  if not exists (select 1 from jsonb_array_elements(p -> 'battle' -> 'adult') x where (x ->> 'here')::boolean and (x ->> 'active')::int >= 3) then
    raise exception 'FAIL 9: battle %', p -> 'battle';
  end if;
  select string_agg(x ->> 'name', ', ' order by x ->> 'name') into v from jsonb_array_elements(p -> 'next_class' -> 'going') x;
  if p -> 'next_class' ->> 'time' is distinct from '23:30' or p -> 'next_class' ->> 'label' is distinct from 'Gi · All Levels'
     or v is distinct from 'Ann Alpha, Kit K.' then
    raise exception 'FAIL 9: next class % going %', p -> 'next_class', v;
  end if;
  raise notice 'PASS 9: chase for 2nd (hidden leader keeps 1st; gap 1), gi Ann / no-gi Cal, battle, next class 23:30 Gi · All Levels going: %', v;

  -- Cases 10 to 12 test the full playlist, so no class may be "on" (157 narrows
  -- the playlist to a Kids or an Adults class running or starting within 30
  -- minutes). Their days are closed at the fixture unit: a closed day keeps only
  -- one-off classes and the fixture has none, so neither the real timetable nor
  -- the fixture class can focus it. Before 157 (or without class_exceptions)
  -- this changes nothing. Values are cast to the table's real column types.
  if to_regclass('public.class_exceptions') is not null then
    select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) into ty
      from pg_attribute a
     where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped;
    select string_agg(a.attname, ', ') into v
      from pg_attribute a
     where a.attrelid = 'public.class_exceptions'::regclass and a.attnum > 0 and not a.attisdropped
       and a.attnotnull and not a.atthasdef and a.attidentity = '' and a.attgenerated = ''
       and a.attname not in ('unit_id', 'exception_date', 'kind');
    if v is not null then raise exception 'FAIL setup: class_exceptions has other required columns: %', v; end if;
    execute format(
      'insert into public.class_exceptions (unit_id, exception_date, kind)
       select $1::text::%s, d::text::%s, ''closed''::text::%s
         from unnest(array[''2031-07-15'', ''2031-08-01'', ''2031-08-03'']) d',
      ty ->> 'unit_id', ty ->> 'exception_date', ty ->> 'kind')
    using ua;
  end if;

  -- 10. playlist: sums to 90, races first, skips what is not true (no class on)
  p := public._tv_payload(scr, '2031-07-15', '12:00');
  select sum((x ->> 'seconds')::int), string_agg(x ->> 'screen', ',' order by o) into n, v
    from jsonb_array_elements(p -> 'playlist') with ordinality t(x, o);
  if n <> 90 or v not like 'race_adults,race_kids,%' or v not like '%rules%' or v not like '%feed%' then
    raise exception 'FAIL 10: % (% s)', v, n;
  end if;
  raise notice 'PASS 10: playlist % = % s', v, n;

  -- 11. between the end and the prizes: final standings, no chase, no rules
  p := public._tv_payload(scr, '2031-08-01', '10:00');
  select sum((x ->> 'seconds')::int), string_agg(x ->> 'screen', ',') into n, v from jsonb_array_elements(p -> 'playlist') x;
  if p -> 'competition' ->> 'phase' is distinct from 'final' or p -> 'competition' ->> 'name' <> 'Zz155 Cup'
     or v like '%chase%' or v like '%rules%' or n <> 90 then
    raise exception 'FAIL 11: % % (% s)', p -> 'competition', v, n;
  end if;
  raise notice 'PASS 11: finale day shows the Cup final standings: % (% s)', v, n;

  -- 12. empty feed skipped; last month's results in the first 7 days (monthly)
  p := public._tv_payload(scr, '2031-08-03', '10:00');
  select string_agg(x ->> 'screen', ',') into v from jsonb_array_elements(p -> 'playlist') x;
  if p -> 'competition' ->> 'kind' <> 'monthly' or v like '%feed%' or v not like '%last_results%'
     or p -> 'last_results' ->> 'month_start' <> '2031-07-01'
     or p -> 'last_results' -> 'adult' -> 0 ->> 'name' is distinct from 'Cal Coach'
     or p::text like '%Hid Den%' then
    raise exception 'FAIL 12: % last %', v, p -> 'last_results';
  end if;
  raise notice 'PASS 12: in August the monthly race, July''s top 3 shown, nothing new so no feed: %', v;
end $$;

rollback;
