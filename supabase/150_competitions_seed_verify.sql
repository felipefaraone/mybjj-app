-- 150_competitions_seed_verify.sql
--
-- V0 (run BEFORE 150): the units the seed will resolve. Expected: exactly one
-- row per name (Camperdown, Neutral Bay). Read-only.
--
-- V1 (run AFTER 150): the seeded data and test 12, inside BEGIN ... ROLLBACK.
-- The LAST statement before ROLLBACK lists every check: expected all pass = true.
-- An empty list, or any pass = false, is a FAILURE.

-- V0 -------------------------------------------------------------------------
select lower(btrim(u.name)) as name_key, count(*) as units, string_agg(u.id::text, ', ') as ids
  from public.units u
 where lower(btrim(u.name)) in ('camperdown', 'neutral bay')
 group by 1 order by 1;

-- V1 -------------------------------------------------------------------------
begin;

create temp table _v150 (n numeric, test text, pass boolean, detail text) on commit drop;

create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  cup uuid; mon uuid; cd uuid; nb uuid; v_txt text; v_txt2 text; u uuid := gen_random_uuid();
  d1 text; d2 text; d3 text; d4 text;
begin
  select c.id into cup from public.competitions c where c.name = 'Christmas Cup 2026' and c.kind = 'event';
  select c.id into mon from public.competitions c where c.name = 'Monthly race' and c.kind = 'monthly';
  select x.id into cd from public.units x where lower(btrim(x.name)) = 'camperdown';
  select x.id into nb from public.units x where lower(btrim(x.name)) = 'neutral bay';

  select format('%s..%s finale %s %s %s', c.starts_on, c.ends_on, c.finale_on, c.status, c.prizes::text) into v_txt
    from public.competitions c where c.id = cup;
  insert into _v150 values (1, 'Christmas Cup 2026: 2 Nov..18 Dec, finale 19 Dec, active, 3 prizes',
    v_txt = '2026-11-02..2026-12-18 finale 2026-12-19 active [{"label": "1st", "place": 1}, {"label": "2nd", "place": 2}, {"label": "3rd", "place": 3}]',
    coalesce(v_txt, 'missing'));
  insert into _v150 values (2, 'Monthly race: monthly, active, no dates',
    exists (select 1 from public.competitions c where c.id = mon and c.status = 'active' and c.starts_on is null and c.ends_on is null),
    coalesce(mon::text, 'missing'));

  select string_agg(format('%s/%s/%s', case d.unit_id when cd then 'CD' when nb then 'NB' else '?' end, d.audience, d.label), ' ' order by d.sort)
    into v_txt from public.competition_divisions d where d.competition_id = cup;
  select string_agg(format('%s/%s/%s', case d.unit_id when cd then 'CD' when nb then 'NB' else '?' end, d.audience, d.label), ' ' order by d.sort)
    into v_txt2 from public.competition_divisions d where d.competition_id = mon;
  insert into _v150 values (3, 'four divisions each: CD kids, CD adults, NB kids, NB adults',
    v_txt = 'CD/kids/Camperdown Kids CD/adult/Camperdown Adults NB/kids/Neutral Bay Kids NB/adult/Neutral Bay Adults' and v_txt2 = v_txt,
    format('cup: %s | monthly: %s', v_txt, v_txt2));

  select string_agg(format('%s=%s%s%s', r.rule_key, r.points, case when r.enabled then '' else '(off)' end,
                           case when r.params <> '{}'::jsonb then r.params::text else '' end), ' ' order by r.rule_key)
    into v_txt from public.competition_rules r where r.competition_id = cup;
  insert into _v150 values (4, 'Cup rules (best_attitude present, 0, disabled)',
    v_txt = 'best_attitude=0(off) class_attended=1{"mode": "class_value", "private_cap": 1} class_challenge=3 referral_conversion=5 referral_trial=3 social_post=2',
    v_txt);
  select string_agg(format('%s=%s%s%s', r.rule_key, r.points, case when r.enabled then '' else '(off)' end,
                           case when r.params <> '{}'::jsonb then r.params::text else '' end), ' ' order by r.rule_key)
    into v_txt from public.competition_rules r where r.competition_id = mon;
  insert into _v150 values (5, 'Monthly rules: class_attended 1, referral_trial 3, referral_conversion 5 (no award rules)',
    v_txt = 'class_attended=1{"mode": "class_value", "private_cap": 1} referral_conversion=5 referral_trial=3', v_txt);

  -- 12. competition_for_date, as an approved member
  insert into auth.users (id, email) values (u, 'zz150-member@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id)
    values (u, 'zz150-member@example.invalid', 'Zz150 Member', 'student', 'approved', cd)
  on conflict (id) do update set status = excluded.status, role = excluded.role;
  perform pg_temp.v_as(u);
  select f.name into d1 from public.competition_for_date(cd, '2026-11-10') f;
  select f.name into d2 from public.competition_for_date(nb, '2026-10-20') f;
  select f.name into d3 from public.competition_for_date(cd, '2026-12-20') f;
  select f.name into d4 from public.competition_for_date(nb, '2026-12-18') f;
  execute 'reset role';
  insert into _v150 values (12, 'competition_for_date: Cup on 10 Nov, Monthly race on 20 Oct and 20 Dec (and Cup on 18 Dec)',
    d1 = 'Christmas Cup 2026' and d2 = 'Monthly race' and d3 = 'Monthly race' and d4 = 'Christmas Cup 2026',
    format('10 Nov %s | 20 Oct %s | 20 Dec %s | 18 Dec %s', d1, d2, d3, d4));
end $$;

select n, test, pass, detail from _v150 order by n;

rollback;
