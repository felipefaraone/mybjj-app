-- 159_competition_battle_source_verify.sql
--
-- Run AFTER 159, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/159_competition_battle_source_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- An ACTIVE July 2031 challenge on the first two units (by name). The battle
-- needs no classes, so the real timetable never matters; the real members of
-- those units have no 2031 attendance, so they add 0 points and no base.
-- competition_unit_battle uses Sydney's real today; the TV payload is pinned to
-- 2031-07-14. They agree because the only part of the formula that reads today
-- (members who joined during the period) is not in the shared fixture; it is
-- checked on its own in 6 with an explicit today.

begin;

create function pg_temp.v_kids_screens(p jsonb) returns boolean language sql immutable as $f$
  select exists (select 1 from jsonb_array_elements(p -> 'playlist') x where x ->> 'screen' = 'battle_kids')
$f$;
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; ub uuid; comp uuid; comp_d uuid; scr uuid; u_mem uuid := gen_random_uuid();
  s_p uuid; s_l uuid; s_h uuid; s_s uuid; s_q uuid; s_ka uuid; s_kb uuid; s_n uuid; s_m uuid;
  p jsonb; v text; n int; rr record;
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  if ua is null or ub is null then raise exception 'FAIL setup: needs two units'; end if;

  -- 1. grants and shape
  if has_function_privilege('anon', 'public.competition_unit_battle(uuid, date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.competition_unit_battle(uuid, date, date)', 'execute')
     or has_function_privilege('anon', 'public._competition_battle(uuid, date, date, date)', 'execute')
     or has_function_privilege('authenticated', 'public._competition_battle(uuid, date, date, date)', 'execute') then
    raise exception 'FAIL 1: grants';
  end if;
  if pg_get_function_result('public.competition_unit_battle(uuid, date, date)'::regprocedure)
     <> 'TABLE(unit_id uuid, unit_name text, audience text, active_students integer, total_classes integer, avg_classes numeric, points numeric, base integer, per_member numeric)' then
    raise exception 'FAIL 1: competition_unit_battle columns %', pg_get_function_result('public.competition_unit_battle(uuid, date, date)'::regprocedure);
  end if;
  raise notice 'PASS 1: competition_unit_battle for authenticated only, 151''s columns in order then points, base, per_member; _competition_battle closed to anon and authenticated';

  -- fixtures
  insert into public.competitions (name, kind, starts_on, ends_on, finale_on, status, prizes)
    values ('Zz159 Cup', 'event', '2031-07-01', '2031-07-31', '2031-08-01', 'active', '[{"place":1,"label":"1st"}]') returning id into comp;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, ua, 'adult', 'zz159 a adults'), (comp, ua, 'kids', 'zz159 a kids'),
    (comp, ub, 'adult', 'zz159 b adults'), (comp, ub, 'kids', 'zz159 b kids');
  insert into public.competition_rules (competition_id, rule_key, points, enabled) values (comp, 'class_attended', 1, true);
  insert into auth.users (id, email) values (u_mem, 'zz159-mem@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id)
    values (u_mem, 'zz159-mem@example.invalid', 'Zz159 Member', 'student', 'approved', ua)
  on conflict (id) do update set email = excluded.email, role = excluded.role, status = excluded.status, unit_id = excluded.unit_id;
  -- first unit adults: P trained before (base); L lapsed and back (points, no base);
  -- H hidden trained before (base, points); S staff trained before (base, points)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz159 Pre P','Pre','P','adult',ua,true,'ok') returning id into s_p;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, created_at)
    values ('Zz159 Lap L','Lap','L','adult',ua,true,'ok', timestamptz '2030-01-01 10:00+10') returning id into s_l;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, leaderboard_hidden)
    values ('Zz159 Hid H','Hid','H','adult',ua,true,'ok',true) returning id into s_h;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, prize_eligible)
    values ('Zz159 Sta S','Sta','S','adult',ua,true,'ok',false) returning id into s_s;
  -- second unit adults: Q trained before
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz159 Que Q','Que','Q','adult',ub,true,'ok') returning id into s_q;
  -- kids at both units who never trained: base 0
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz159 Kid A','Kid','A','kids',ua,true,'ok','white') returning id into s_ka;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, belt)
    values ('Zz159 Kid B','Kid','B','kids',ub,true,'ok','white') returning id into s_kb;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
  select x.sid, null, x.d, '07:00', 'alev', 'present', 1.00, 'gi', x.u
    from (values (s_p, date '2031-06-10', ua), (s_p, date '2031-07-02', ua),
                 (s_l, date '2031-03-01', ua), (s_l, date '2031-07-03', ua), (s_l, date '2031-07-04', ua),
                 (s_h, date '2031-06-15', ua), (s_h, date '2031-07-02', ua),
                 (s_s, date '2031-06-20', ua), (s_s, date '2031-07-05', ua),
                 (s_q, date '2031-06-20', ub), (s_q, date '2031-07-02', ub), (s_q, date '2031-07-03', ub)) x(sid, d, u);
  insert into public.tv_screens (name, unit_id, token_hash, show_battle)
    values ('zz159 tv', ua, encode(sha256('zz159-a'::bytea), 'hex'), true) returning id into scr;

  -- 2. the app and the TV give the same battle, per unit and audience
  p := public._tv_payload(scr, '2031-07-14', '10:00');
  perform pg_temp.v_as(u_mem);
  create temp table b159 on commit drop as select * from public.competition_unit_battle(comp, null, null);
  execute 'reset role';
  select count(*) into n from b159;
  if n = 0 then raise exception 'FAIL 2: no battle rows for the member'; end if;
  select string_agg(format('%s/%s %s', b.unit_name, b.audience, b.points), '; ') into v
    from b159 b
   where not exists (select 1 from jsonb_array_elements(p -> 'battle' -> b.audience) e
                      where e ->> 'unit' = b.unit_name
                        and (e ->> 'points')::numeric = b.points
                        and (e ->> 'base')::int = b.base
                        and (e ->> 'per_member')::numeric is not distinct from b.per_member
                        and (e ->> 'here')::boolean = (b.unit_id = ua));
  if v is not null then raise exception 'FAIL 2: differ: % / TV %', v, p -> 'battle'; end if;
  if (select count(*) from b159) <> (select count(*) from jsonb_each(p -> 'battle') a, jsonb_array_elements(a.value) e) then
    raise exception 'FAIL 2: row counts differ';
  end if;
  raise notice 'PASS 2: competition_unit_battle and the TV payload agree on points / base / per_member for all % rows', n;

  -- 3. 158's numbers: first unit adults 5 points / base 3 = 1.67; second unit 2 / 1 = 2.00
  select * into rr from b159 where unit_id = ua and audience = 'adult';
  if rr.points <> 5 or rr.base <> 3 or rr.per_member <> 1.67 then raise exception 'FAIL 3: first unit %', rr; end if;
  select * into rr from b159 where unit_id = ub and audience = 'adult';
  if rr.points <> 2 or rr.base <> 1 or rr.per_member <> 2.00 then raise exception 'FAIL 3: second unit %', rr; end if;
  raise notice 'PASS 3: points per member: first unit 5 / 3 = 1.67 (staff and hidden in, the lapsed member not in the base), second 2 / 1 = 2.00';

  -- 4. the old columns are 151's: active / total over _competition_scores
  select string_agg(format('%s/%s', o.unit_id, o.audience), '; ') into v
    from (select s.unit_id, s.audience,
                 (count(*) filter (where s.classes_count > 0))::integer as act,
                 coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0)::integer as tot,
                 case when count(*) filter (where s.classes_count > 0) = 0 then 0::numeric
                      else (coalesce(sum(s.classes_count) filter (where s.classes_count > 0), 0))::numeric
                           / (count(*) filter (where s.classes_count > 0))::numeric end as av
            from public._competition_scores(comp, null, null) s
           group by s.unit_id, s.audience) o
    left join b159 b on b.unit_id = o.unit_id and b.audience = o.audience
   where b.unit_id is null or b.active_students <> o.act or b.total_classes <> o.tot or b.avg_classes <> o.av;
  if v is not null then raise exception 'FAIL 4: old columns differ from 151 for %', v; end if;
  raise notice 'PASS 4: active_students / total_classes / avg_classes equal 151''s formula';

  -- 5. base 0: per_member null (the kids never trained)
  select string_agg(format('%s:%s/%s', b.unit_id = ua, b.base, coalesce(b.per_member::text, 'null')), ' ') into v
    from b159 b where b.audience = 'kids' and b.unit_id in (ua, ub);
  if v is null or v ~ '/[0-9]' or v ~ ':[1-9]' then raise exception 'FAIL 5: %', v; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'battle' -> 'kids') e where e ->> 'per_member' is not null)
     or pg_temp.v_kids_screens(p) then
    raise exception 'FAIL 5: per_member set on the TV, or a kids battle screen';
  end if;
  raise notice 'PASS 5: kids base 0 at both units: per_member null (%), on the TV too, no kids battle screen', v;

  -- 6. who joined during the period counts once they have trained (today bounds it)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, created_at)
    values ('Zz159 New N','New','N','adult',ua,true,'ok', timestamptz '2031-07-05 10:00+10') returning id into s_n;
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, modality, unit_id)
    values (s_n, null, '2031-07-06', '07:00', 'alev', 'present', 1.00, 'gi', ua);
  select b.base || '/' || b.points into v from public._competition_battle(comp, null, null, '2031-07-14') b where b.unit_id = ua and b.audience = 'adult';
  if v <> '4/6.00' then raise exception 'FAIL 6: after training %', v; end if;
  select b.base || '/' || b.points into v from public._competition_battle(comp, null, null, '2031-07-05') b where b.unit_id = ua and b.audience = 'adult';
  if v <> '3/6.00' then raise exception 'FAIL 6: before training %', v; end if;
  raise notice 'PASS 6: a member who joined in the period: in the base from the day they trained (4), not before (3)';

  -- 7. 151's guards: a draft gives a member nothing; a caller who is not approved is refused
  insert into public.competitions (name, kind, starts_on, ends_on, status, prizes)
    values ('Zz159 Draft', 'event', '2031-09-01', '2031-09-30', 'draft', '[]') returning id into comp_d;
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values (comp_d, ua, 'adult', 'zz159 d');
  perform pg_temp.v_as(u_mem);
  select count(*) into n from public.competition_unit_battle(comp_d, null, null);
  execute 'reset role';
  if n <> 0 then raise exception 'FAIL 7: draft gave % rows', n; end if;
  update public.users set status = 'pending' where id = u_mem;
  perform pg_temp.v_as(u_mem);
  begin
    perform public.competition_unit_battle(comp, null, null);
    v := 'accepted';
  exception when insufficient_privilege then v := 'insufficient_privilege';
  end;
  execute 'reset role';
  if v <> 'insufficient_privilege' then raise exception 'FAIL 7: not approved: %', v; end if;
  raise notice 'PASS 7: draft: no rows for a member; not approved: insufficient_privilege';
end $$;

rollback;
