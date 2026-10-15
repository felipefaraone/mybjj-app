-- 151_competitions_staff_controls_verify.sql
--
-- Checks for 151, inside BEGIN ... ROLLBACK: nothing persists. A synthetic DRAFT
-- event in July 2031 on the first unit (by name) and a synthetic active monthly
-- race. Callers are simulated with request.jwt.claims + SET LOCAL ROLE
-- authenticated, as PostgREST does.
-- The LAST statement before ROLLBACK lists every check: expected all pass = true.
-- An empty list, or any pass = false, is a FAILURE.

begin;

create temp table _v151 (n numeric, test text, pass boolean, detail text) on commit drop;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; dr uuid; mo uuid; st uuid;
  u_admin uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_mem uuid := gen_random_uuid();
  v_txt text; v_err text; n int; n2 int; v_ok boolean;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  if ua is null then raise exception 'V151 needs one unit'; end if;

  insert into auth.users (id, email) values
    (u_admin, 'zz151-admin@example.invalid'), (u_staff, 'zz151-staff@example.invalid'), (u_mem, 'zz151-member@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_admin, 'zz151-admin@example.invalid',  'Zz151 Admin',  'student',    'approved', ua),
    (u_staff, 'zz151-staff@example.invalid',  'Zz151 Staff',  'instructor', 'approved', ua),
    (u_mem,   'zz151-member@example.invalid', 'Zz151 Member', 'student',    'approved', ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_admin) on conflict do nothing;

  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status)
    values ('Zz151 Draft Cup', 'event', '2031-07-01', '2031-07-30', '2031-07-31', 'draft') returning id into dr;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (dr, ua, 'adult', 'Zz151 Adults'), (dr, ua, 'kids', 'Zz151 Kids');
  insert into public.competition_rules (competition_id, rule_key, points, params, enabled) values
    (dr, 'class_attended', 1, '{"mode":"class_value","private_cap":1}', true),
    (dr, 'class_challenge', 3, '{}', true), (dr, 'social_post', 2, '{}', true), (dr, 'best_attitude', 0, '{}', false);
  -- the newest active monthly race is the one competition_for_date picks
  insert into public.competitions (name, kind, status) values ('Zz151 Monthly', 'monthly', 'active') returning id into mo;
  insert into public.competition_rules (competition_id, rule_key, points, params) values
    (mo, 'class_attended', 1, '{"mode":"class_value","private_cap":1}'), (mo, 'referral_trial', 3, '{}'), (mo, 'referral_conversion', 5, '{}');
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz151 Ana Alpha', 'Ana', 'Alpha', 'adult', ua, true, 'ok') returning id into st;
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id)
    values (st, '2031-07-05', 'beg', 'present', 1.00, 'gi', ua);

  -- 1. admin on a Cup date gets the DRAFT Cup rules
  perform pg_temp.v_as(u_admin);
  select string_agg(format('%s=%s%s', r.rule_key, r.points, case when r.enabled then '' else '(off)' end), ' ' order by r.rule_key),
         bool_and(r.competition_id = dr and r.status = 'draft' and r.competition_name = 'Zz151 Draft Cup')
    into v_txt, v_ok
    from public.competition_rules_for_date(ua, '2031-07-10') r;
  execute 'reset role';
  insert into _v151 values (1, 'admin on a Cup date: the draft Cup rules (best_attitude present, disabled)',
    coalesce(v_ok, false) and v_txt = 'best_attitude=0(off) class_attended=1 class_challenge=3 social_post=2', coalesce(v_txt, '(none)'));

  -- 2. non-admin staff on the same date: the monthly race
  perform pg_temp.v_as(u_staff);
  select string_agg(r.rule_key, ' ' order by r.rule_key),
         bool_and(r.competition_id = mo and r.status = 'active')
    into v_txt, v_ok
    from public.competition_rules_for_date(ua, '2031-07-10') r;
  execute 'reset role';
  insert into _v151 values (2, 'non-admin staff on the same date: the active monthly race rules (never the draft)',
    coalesce(v_ok, false) and v_txt = 'class_attended referral_conversion referral_trial', coalesce(v_txt, '(none)'));

  -- 2.1 admin outside the Cup dates: the monthly race too
  perform pg_temp.v_as(u_admin);
  select bool_and(r.competition_id = mo) into v_ok from public.competition_rules_for_date(ua, '2031-08-10') r;
  execute 'reset role';
  insert into _v151 values (2.1, 'admin outside the Cup dates: the monthly race', coalesce(v_ok, false), coalesce(v_ok::text, '(none)'));

  -- 3. a member who is not staff is refused
  perform pg_temp.v_as(u_mem);
  begin
    perform 1 from public.competition_rules_for_date(ua, '2031-07-10');
    v_err := 'returned';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  execute 'reset role';
  insert into _v151 values (3, 'member (not staff) refused', v_err = 'insufficient_privilege', v_err);

  -- 4. standings / unit battle of a draft: 0 rows for staff, rows for admin
  perform pg_temp.v_as(u_staff);
  select count(*) into n from public.competition_standings(dr);
  select count(*) into n2 from public.competition_unit_battle(dr);
  execute 'reset role';
  insert into _v151 values (4, 'draft standings and unit battle: 0 rows for non-admin staff', n = 0 and n2 = 0, format('standings %s, battle %s', n, n2));
  perform pg_temp.v_as(u_admin);
  select count(*) into n from public.competition_standings(dr) x where x.student_id = st;
  select count(*) into n2 from public.competition_unit_battle(dr);
  execute 'reset role';
  insert into _v151 values (4.1, 'draft standings and unit battle: rows for admin', n = 1 and n2 >= 1, format('Ana rows %s, battle rows %s', n, n2));

  -- 5. once active, staff get the Cup rules and its standings
  update public.competitions set status = 'active' where id = dr;
  perform pg_temp.v_as(u_staff);
  select bool_and(r.competition_id = dr and r.status = 'active') into v_ok from public.competition_rules_for_date(ua, '2031-07-10') r;
  select count(*) into n from public.competition_standings(dr) x where x.student_id = st;
  execute 'reset role';
  insert into _v151 values (5, 'after activation: non-admin staff get the Cup rules and its standings', coalesce(v_ok, false) and n = 1,
    format('cup rules %s, Ana rows %s', v_ok, n));
end $$;

select n, test, pass, detail from _v151 order by n;

rollback;
