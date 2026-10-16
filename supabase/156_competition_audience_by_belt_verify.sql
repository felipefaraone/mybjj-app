-- 156_competition_audience_by_belt_verify.sql
--
-- Run AFTER 156, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/156_competition_audience_by_belt_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic people and two synthetic ACTIVE challenges in July and August 2031
-- on the first unit (by name).

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; cls uuid; comp uuid; comp2 uuid; scr uuid;
  u_mem uuid := gen_random_uuid(); u_gj uuid := gen_random_uuid(); u_gk uuid := gen_random_uuid();
  s_jack uuid; s_kw uuid; s_kg uuid; s_aw uuid; s_ab uuid; s_mem uuid;
  a1 uuid; a2 uuid; p jsonb; v text; n int;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select c.id into cls from public.classes c order by c.id limit 1;
  if ua is null or cls is null then raise exception 'FAIL setup: needs a unit and a class'; end if;

  -- 1. the division rule and the minor rule
  select string_agg(coalesce(x.prog, 'null') || '/' || coalesce(x.belt, 'null') || '=' || public._competition_audience(x.prog, x.belt), ' ')
    into v
    from (values ('kids','blue'), ('kids',' Purple '), ('kids','BROWN'), ('kids','black'), ('kids','grey/white'),
                 ('kids','white'), ('kids',null), ('kids','yellow'), ('adult','white'), (null,null), ('adult','blue')) x(prog, belt);
  if v <> 'kids/blue=adult kids/ Purple =adult kids/BROWN=adult kids/black=adult kids/grey/white=kids kids/white=kids kids/null=kids kids/yellow=kids adult/white=adult null/null=adult adult/blue=adult' then
    raise exception 'FAIL 1: %', v;
  end if;
  if not public._competition_minor('kids') or public._competition_minor('adult') or public._competition_minor(null) then
    raise exception 'FAIL 1: _competition_minor';
  end if;
  raise notice 'PASS 1: %; minor = prog kids only', v;

  -- 2. the old rule is gone and nothing calls it
  if to_regprocedure('public._competition_audience(text)') is not null then raise exception 'FAIL 2: 1-argument version still exists'; end if;
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosrc ~ '_competition_audience\(\s*(?:[^(),]|\([^()]*\))*\)';
  if v is not null then raise exception 'FAIL 2: still calling the 1-argument rule: %', v; end if;
  raise notice 'PASS 2: _competition_audience(text) dropped; no function body calls a 1-argument form';

  -- 3. grants: internals closed, standings for authenticated only
  if has_function_privilege('authenticated', 'public._competition_audience(text, text)', 'execute')
     or has_function_privilege('anon', 'public._competition_minor(text)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_minor(text)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_scores(uuid, date, date)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_ranked(uuid, date, date)', 'execute')
     or has_function_privilege('anon', 'public.competition_standings(uuid, date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_standings(uuid, date, date)', 'execute') then
    raise exception 'FAIL 3: grants changed';
  end if;
  raise notice 'PASS 3: grants as before (internals closed, competition_standings for authenticated)';

  -- fixtures: July 2031 challenge with adults + kids boards; August 2031 with an adults board only
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz156 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz156 adults'), (comp, ua, 'kids', 'zz156 kids');
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz156 Adults', 'event', '2031-08-10', '2031-08-31', null, 'active', '[]') returning id into comp2;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp2, ua, 'adult', 'zz156b adults');
  insert into public.competition_rules (competition_id, rule_key, points, enabled)
    select x.c, k.k, k.p, true
      from (values (comp), (comp2)) x(c)
     cross join (values ('class_attended', 1), ('class_challenge', 3), ('social_post', 2)) k(k, p);

  insert into auth.users (id, email) values (u_mem, 'zz156-mem@example.invalid'), (u_gj, 'zz156-gj@example.invalid'), (u_gk, 'zz156-gk@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_mem, 'zz156-mem@example.invalid', 'Zz156 Member', 'student', 'approved', ua),
    (u_gj,  'zz156-gj@example.invalid',  'Zz156 Guardian J', 'parent', 'approved', ua),
    (u_gk,  'zz156-gk@example.invalid',  'Zz156 Guardian K', 'parent', 'approved', ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  -- Jacky: kids programme on a blue belt (the Jack Howells case)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, degree, photo_url)
    values ('Zz156 Jacky Howl','Jacky','Howl','kids',ua,true,'ok','blue',3,'zz156/jacky.jpg') returning id into s_jack;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, photo_url)
    values ('Zz156 Kim White','Kim','White','kids',ua,true,'ok','white','zz156/kim.jpg') returning id into s_kw;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz156 Gus Grey','Gus','Grey','kids',ua,true,'ok','grey/white') returning id into s_kg;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, photo_url)
    values ('Zz156 Amy White','Amy','White','adult',ua,true,'ok','white','zz156/amy.jpg') returning id into s_aw;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz156 Abe Blue','Abe','Blue','adult',ua,true,'ok','blue') returning id into s_ab;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt, user_id)
    values ('Zz156 Mel Member','Mel','Member','adult',ua,true,'ok','white',u_mem) returning id into s_mem;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access) values
    (s_jack, u_gj, 'active', 'legacy_sync', 'manage'), (s_kw, u_gk, 'active', 'legacy_sync', 'manage');
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, x.d, '18:00', 'alev', 'present', 1.00, 'gi', ua
    from (values (s_jack, date '2031-07-01'), (s_jack, date '2031-07-02'), (s_jack, date '2031-07-03'),
                 (s_kw, date '2031-07-01'), (s_kg, date '2031-07-01'), (s_aw, date '2031-07-01'), (s_ab, date '2031-07-01'),
                 (s_mem, date '2031-07-01')) x(sid, d);

  -- 4. Jacky ranks on the adults board as a child; kids white / grey stay kids; adult white stays adult
  select string_agg(r.audience || ':' || r.display_name || ':' || coalesce(r.photo_url, 'nophoto') || ':' || r.minor::text, ' | ' order by r.display_name)
    into v from public._competition_ranked(comp, null, null) r
   where r.student_id in (s_jack, s_kw, s_kg, s_aw, s_ab);
  if v <> 'adult:Abe Blue:nophoto:false | adult:Amy White:zz156/amy.jpg:false | kids:Gus G.:nophoto:true | adult:Jacky H.:nophoto:true | kids:Kim W.:nophoto:true' then
    raise exception 'FAIL 4: %', v;
  end if;
  if (select r.rank from public._competition_ranked(comp, null, null) r where r.student_id = s_jack) <> 1 then
    raise exception 'FAIL 4: Jacky (3 classes) should lead the adults board';
  end if;
  raise notice 'PASS 4: %', v;

  -- 5. what members see: Jacky on adults as a child, no kids board
  perform pg_temp.v_as(u_mem);
  select string_agg(r.audience || ':' || r.display_name || ':' || coalesce(r.photo_url, 'nophoto') || ':' || r.minor::text, ' | ' order by r.display_name),
         count(*) filter (where r.audience = 'kids')
    into v, n from public.competition_standings(comp, null, null) r where r.student_id in (s_jack, s_kw, s_kg, s_aw, s_ab);
  execute 'reset role';
  if v <> 'adult:Abe Blue:nophoto:false | adult:Amy White:zz156/amy.jpg:false | adult:Jacky H.:nophoto:true' or n <> 0 then
    raise exception 'FAIL 5: % (kids rows %)', v, n;
  end if;
  raise notice 'PASS 5: a member sees %; no kids rows', v;

  -- 6. guardians: a real kid's guardian still sees the kids board; Jacky's guardian
  -- (his child is on the adults board now) sees adults only
  perform pg_temp.v_as(u_gk);
  select count(*) into n from public.competition_standings(comp, null, null) r where r.audience = 'kids' and r.student_id in (s_kw, s_kg);
  execute 'reset role';
  if n <> 2 then raise exception 'FAIL 6: the kid''s guardian sees % kids rows', n; end if;
  perform pg_temp.v_as(u_gj);
  select count(*) filter (where r.audience = 'kids'), count(*) filter (where r.student_id = s_jack and r.audience = 'adult')
    into n, v from public.competition_standings(comp, null, null) r;
  execute 'reset role';
  if n <> 0 or v <> '1' then raise exception 'FAIL 6: Jacky''s guardian kids rows % / Jacky on adults %', n, v; end if;
  raise notice 'PASS 6: kids board for a real kid''s guardian unchanged; Jacky''s guardian sees him on adults';

  -- 7. the TV: Jacky in adults, minor, initial name, no photo; also in the going list as a child
  insert into public.tv_screens (name, unit_id, token_hash) values ('zz156 tv', ua, encode(sha256('zz156-tv'::bytea), 'hex')) returning id into scr;
  p := public._tv_payload(scr, '2031-07-15', '10:00');
  select string_agg((e ->> 'name') || ':' || (e ->> 'minor') || ':' || coalesce(e ->> 'photo_path', 'nophoto'), ' | ' order by e ->> 'name') into v
    from jsonb_array_elements(p -> 'boards' -> 'adult' -> 'rows') e where e ->> 'name' in ('Jacky H.', 'Amy White', 'Abe Blue');
  if v <> 'Abe Blue:false:nophoto | Amy White:false:zz156/amy.jpg | Jacky H.:true:nophoto'
     or exists (select 1 from jsonb_array_elements(p -> 'boards' -> 'kids' -> 'rows') e where e ->> 'name' = 'Jacky H.')
     or not exists (select 1 from jsonb_array_elements(p -> 'boards' -> 'kids' -> 'rows') e where e ->> 'name' = 'Kim W.' and (e ->> 'minor')::boolean)
     or p::text like '%jacky.jpg%' or p::text like '%kim.jpg%' then
    raise exception 'FAIL 7: adults % / payload %', v, p -> 'boards';
  end if;
  raise notice 'PASS 7: TV adults board %; Jacky not on kids; no kid photo anywhere', v;

  -- 8. 154's trigger: the presence rule through _competition_award_counts, guard intact,
  -- and the division by belt (Zz156 Adults has no kids board: Jacky is notified)
  select p.prosrc into v from pg_proc p where p.oid = 'public.competition_awards_notify()'::regprocedure;
  if position('_competition_award_counts(NEW.student_id, NEW.class_id, NEW.class_date)' in v) = 0
     or position('from public.attendance' in v) > 0
     or position('exception when others then' in v) = 0
     or position('154 notify skipped' in v) = 0 then
    raise exception 'FAIL 8: trigger text';
  end if;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (s_jack, cls, '2031-08-12', '18:00', 'alev', 'present', 1.00, ua);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (s_jack, 'class_challenge', '2031-08-12', cls, '2031-08-12') returning id into a1;
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (s_jack, 'class_challenge', '2031-08-13', cls, '2031-08-13') returning id into a2;   -- not present
  select string_agg(nf.title, ' ; ') into v from public.notifications nf where nf.related_entity_id = a1 and nf.user_id = u_gj;
  if v is distinct from 'Jacky won the class challenge · +3'
     or exists (select 1 from public.notifications nf where nf.related_entity_id = a2) then
    raise exception 'FAIL 8: % / no-presence award notified: %', v, exists (select 1 from public.notifications nf where nf.related_entity_id = a2);
  end if;
  raise notice 'PASS 8: 154 trigger via _competition_award_counts, guard intact; Jacky''s guardian: %; no notification without presence', v;
end $$;

rollback;
