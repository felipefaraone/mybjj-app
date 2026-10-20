-- 153_competitions_owner_tools_verify.sql
--
-- Run AFTER 153, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/153_competitions_owner_tools_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Synthetic callers (admin = owner of the first unit, staff = instructor) and
-- synthetic challenges in 2031; callers simulated as PostgREST does.

begin;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; ub uuid; ua_name text; s1 uuid; s2 uuid; s3 uuid;
  u_admin uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid();
  rules jsonb; c1 uuid; c2 uuid; c3 uuid; v_err text; v_txt text; n int;
begin
  select u.id, u.name into ua, ua_name from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  select s.id into s1 from public.students s order by s.id limit 1;
  select s.id into s2 from public.students s order by s.id offset 1 limit 1;
  select s.id into s3 from public.students s order by s.id offset 2 limit 1;
  if ua is null or ub is null or s3 is null then raise exception 'FAIL setup: needs two units and three students'; end if;

  insert into auth.users (id, email) values (u_admin, 'zz153-admin@example.invalid'), (u_staff, 'zz153-staff@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_admin, 'zz153-admin@example.invalid', 'Zz153 Admin', 'student',    'approved', ua),
    (u_staff, 'zz153-staff@example.invalid', 'Zz153 Staff', 'instructor', 'approved', ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_admin) on conflict do nothing;

  select jsonb_agg(jsonb_build_object('rule_key', c.key,
           'points', case c.key when 'class_attended' then 1 when 'class_challenge' then 3 when 'social_post' then 2
                                when 'referral_trial' then 3 when 'referral_conversion' then 5 else 1 end,
           'enabled', c.key <> 'best_attitude') order by c.sort)
    into rules from public.competition_rule_catalog c;

  -- 1. a non-admin (staff) cannot call any of the three
  perform pg_temp.v_as(u_staff);
  v_err := '';
  begin perform public.competition_save(jsonb_build_object('name','zz153 x','starts_on','2031-07-01','ends_on','2031-07-31','rules',rules,
                                         'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
        v_err := v_err || 'save:accepted ';
  exception when insufficient_privilege then v_err := v_err || 'save:refused '; end;
  begin perform public.competition_set_status(gen_random_uuid(), 'active'); v_err := v_err || 'status:accepted ';
  exception when insufficient_privilege then v_err := v_err || 'status:refused '; end;
  begin perform public.competition_award_add_many(array[s1], 'social_post', '2031-07-02'); v_err := v_err || 'many:accepted';
  exception when insufficient_privilege then v_err := v_err || 'many:refused'; end;
  execute 'reset role';
  if v_err <> 'save:refused status:refused many:refused' then raise exception 'FAIL 1: %', v_err; end if;
  raise notice 'PASS 1: non-admin refused by competition_save, competition_set_status, competition_award_add_many (social_post)';

  -- 2. save: insert (draft, prizes, every rule, divisions with 150 labels)
  perform pg_temp.v_as(u_admin);
  c1 := public.competition_save(jsonb_build_object('name','  Zz153 Winter Cup ','starts_on','2031-07-01','ends_on','2031-07-30','finale_on','2031-07-31',
          'places',3,'rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'),jsonb_build_object('unit_id',ua,'audience','kids'))));
  execute 'reset role';
  select format('%s|%s|%s|%s', c.name, c.status, c.kind, c.prizes::text) into v_txt from public.competitions c where c.id = c1;
  if v_txt <> 'Zz153 Winter Cup|draft|event|[{"label": "1st", "place": 1}, {"label": "2nd", "place": 2}, {"label": "3rd", "place": 3}]' then
    raise exception 'FAIL 2: inserted row %', v_txt; end if;
  select count(*) into n from public.competition_rules where competition_id = c1;
  if n <> (select count(*) from public.competition_rule_catalog) then raise exception 'FAIL 2: % rules', n; end if;
  select string_agg(d.label || '/' || d.sort, ', ' order by d.sort) into v_txt from public.competition_divisions d where d.competition_id = c1;
  if v_txt <> ua_name || ' Kids/1, ' || ua_name || ' Adults/2' then raise exception 'FAIL 2: divisions %', v_txt; end if;
  raise notice 'PASS 2: save inserts a draft with prizes 1st-3rd, every catalog rule and 150-style divisions';

  -- 3. save: update (rule upsert, division set replaced, still draft)
  perform pg_temp.v_as(u_admin);
  perform public.competition_save(jsonb_build_object('id',c1,'name','Zz153 Winter Cup 2','starts_on','2031-07-01','ends_on','2031-07-30','places',5,
          'rules',(select jsonb_agg(case when e->>'rule_key' = 'class_challenge' then jsonb_set(e,'{points}','4') else e end) from jsonb_array_elements(rules) e),
          'divisions',jsonb_build_array(jsonb_build_object('unit_id',ub,'audience','adult'))));
  execute 'reset role';
  select format('%s|%s|%s|%s', c.name, c.status, jsonb_array_length(c.prizes), c.finale_on) into v_txt from public.competitions c where c.id = c1;
  if v_txt <> 'Zz153 Winter Cup 2|draft|5|<NULL>' and v_txt <> 'Zz153 Winter Cup 2|draft|5|' then raise exception 'FAIL 3: row %', v_txt; end if;
  select r.points into n from public.competition_rules r where r.competition_id = c1 and r.rule_key = 'class_challenge';
  if n <> 4 then raise exception 'FAIL 3: class_challenge points %', n; end if;
  select count(*) into n from public.competition_rules where competition_id = c1;
  if n <> (select count(*) from public.competition_rule_catalog) then raise exception 'FAIL 3: % rules after upsert', n; end if;
  select string_agg(d.unit_id::text || '/' || d.audience, ',') into v_txt from public.competition_divisions d where d.competition_id = c1;
  if v_txt <> ub::text || '/adult' then raise exception 'FAIL 3: divisions %', v_txt; end if;
  raise notice 'PASS 3: save updates, upserts rules (no duplicates) and replaces the division set';

  -- 3.1 validation messages
  perform pg_temp.v_as(u_admin);
  v_txt := '';
  begin perform public.competition_save(jsonb_build_object('name','  ','starts_on','2031-07-01','ends_on','2031-07-30','rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
  exception when invalid_parameter_value then v_txt := v_txt || sqlerrm || '|'; end;
  begin perform public.competition_save(jsonb_build_object('name','x','starts_on','2031-07-10','ends_on','2031-07-01','rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
  exception when invalid_parameter_value then v_txt := v_txt || sqlerrm || '|'; end;
  begin perform public.competition_save(jsonb_build_object('name','x','starts_on','2031-07-01','ends_on','2031-07-10','finale_on','2031-07-05','rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
  exception when invalid_parameter_value then v_txt := v_txt || sqlerrm || '|'; end;
  begin perform public.competition_save(jsonb_build_object('name','x','starts_on','2031-07-01','ends_on','2031-07-10','rules',rules,'divisions','[]'::jsonb));
  exception when invalid_parameter_value then v_txt := v_txt || sqlerrm || '|'; end;
  begin perform public.competition_save(jsonb_build_object('name','x','starts_on','2031-07-01','ends_on','2031-07-10',
          'rules',(select jsonb_agg(case when e->>'rule_key' = 'social_post' then jsonb_set(e,'{points}','0') else e end) from jsonb_array_elements(rules) e),
          'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
  exception when invalid_parameter_value then v_txt := v_txt || sqlerrm || '|'; end;
  execute 'reset role';
  if v_txt <> 'Add a name|The end can''t be before the start|Prizes can''t be before the end|Pick at least one group|Points must be more than 0|' then
    raise exception 'FAIL 3.1: %', v_txt; end if;
  raise notice 'PASS 3.1: validation messages';

  -- 4. overlap refusal (active event at the same unit, overlapping through the finale)
  perform pg_temp.v_as(u_admin);
  c2 := public.competition_save(jsonb_build_object('name','Zz153 Spring','starts_on','2031-08-01','ends_on','2031-08-20','finale_on','2031-08-22','places',3,
          'rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','adult'))));
  perform public.competition_set_status(c2, 'active');
  c3 := public.competition_save(jsonb_build_object('name','Zz153 Clash','starts_on','2031-08-22','ends_on','2031-08-30','places',3,
          'rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ua,'audience','kids'))));
  begin perform public.competition_set_status(c3, 'active'); v_err := 'accepted';
  exception when invalid_parameter_value then v_err := sqlerrm; end;
  execute 'reset role';
  if v_err <> 'Zz153 Spring already runs at ' || ua_name || ' on those dates' then raise exception 'FAIL 4: %', v_err; end if;
  if (select status from public.competitions where id = c3) <> 'draft' then raise exception 'FAIL 4: clash went active'; end if;
  raise notice 'PASS 4: overlap refused, message names the unit: %', v_err;

  -- 4.1 no overlap when the units differ (c1 is at the second unit)
  perform pg_temp.v_as(u_admin);
  perform public.competition_save(jsonb_build_object('id',c1,'name','Zz153 Winter Cup 2','starts_on','2031-08-05','ends_on','2031-08-10','places',3,
          'rules',rules,'divisions',jsonb_build_array(jsonb_build_object('unit_id',ub,'audience','adult'))));
  perform public.competition_set_status(c1, 'active');
  execute 'reset role';
  if (select status from public.competitions where id = c1) <> 'active' then raise exception 'FAIL 4.1: other-unit event not activated'; end if;
  raise notice 'PASS 4.1: an overlapping event at another unit activates';

  -- 5. draft refused once started; allowed before the start
  update public.competitions set starts_on = (now() at time zone 'Australia/Sydney')::date - 1 where id = c2;
  perform pg_temp.v_as(u_admin);
  begin perform public.competition_set_status(c2, 'draft'); v_err := 'accepted';
  exception when invalid_parameter_value then v_err := sqlerrm; end;
  perform public.competition_set_status(c1, 'draft');
  execute 'reset role';
  if v_err not like '%already started%' then raise exception 'FAIL 5: %', v_err; end if;
  if (select status from public.competitions where id = c1) <> 'draft' then raise exception 'FAIL 5: future event not back to draft'; end if;
  raise notice 'PASS 5: draft refused after the start, allowed before it';

  -- 6. add_many: added / already, never a duplicate
  perform pg_temp.v_as(u_admin);
  select string_agg(x.result, ',' order by x.result) into v_txt from public.competition_award_add_many(array[s1, s2], 'social_post', '2031-07-02') x;
  if v_txt <> 'added,added' then raise exception 'FAIL 6: first call %', v_txt; end if;
  select string_agg(y.k, ',' order by y.k) into v_txt
    from (select case x.student_id when s1 then 'a' when s2 then 'b' else 'c' end || '=' || x.result as k
            from public.competition_award_add_many(array[s1, s2, s3, s3], 'social_post', '2031-07-02') x) y;
  execute 'reset role';
  if v_txt <> 'a=already,b=already,c=added' then raise exception 'FAIL 6: second call %', v_txt; end if;
  select count(*) into n from public.competition_awards
   where award_key = 'social_post' and award_date = '2031-07-02' and voided_at is null and student_id in (s1, s2, s3);
  if n <> 3 then raise exception 'FAIL 6: % live awards (expected 3)', n; end if;
  raise notice 'PASS 6: add_many returns added / already and never duplicates';

  -- 6.1 unknown student -> not_allowed; class awards need competition_award_add
  perform pg_temp.v_as(u_admin);
  select x.result into v_txt from public.competition_award_add_many(array[gen_random_uuid()], 'social_post', '2031-07-03') x;
  begin perform public.competition_award_add_many(array[s1], 'class_challenge', '2031-07-03'); v_err := 'accepted';
  exception when invalid_parameter_value then v_err := 'refused'; end;
  execute 'reset role';
  if v_txt <> 'not_allowed' or v_err <> 'refused' then raise exception 'FAIL 6.1: % / %', v_txt, v_err; end if;
  raise notice 'PASS 6.1: unknown student = not_allowed; class awards refused';

  -- 7. catalog copy (153's six rules; later rules, such as 163's self_checkin, carry their own copy)
  select string_agg(k.key || '=' || k.label || '|' || coalesce(k.description, '-'), '; ' order by k.sort) into v_txt from public.competition_rule_catalog k
   where k.key in ('class_attended', 'social_post', 'class_challenge', 'best_attitude', 'referral_trial', 'referral_conversion');
  if v_txt <> 'class_attended=Train a class|Part classes count as marked (½ or ¼). A private counts as 1.; social_post=Post, story or reel about myBJJ|Once a day counts; class_challenge=Win the class challenge|-; best_attitude=Best attitude in class|Picked by the coach; referral_trial=Bring a friend to a trial|-; referral_conversion=Your friend signs up|On top of the trial points' then
    raise exception 'FAIL 7: %', v_txt; end if;
  raise notice 'PASS 7: catalog copy updated';
end $$;

rollback;
