-- 149_competitions_functions_verify.sql
--
-- Tests 1-11 of the competitions engine, inside BEGIN ... ROLLBACK: nothing
-- persists. Synthetic people ("Zz149 ...") and synthetic competitions in July /
-- August 2031, on the first two units (by name). Real students of those units
-- appear on the synthetic boards with 0 points (no 2031 attendance) and never
-- change these results. Callers are simulated with request.jwt.claims + SET
-- LOCAL ROLE authenticated, as PostgREST does.
-- Needs: 148 and 149 applied; at least two units and one class in public.classes.
--
-- The LAST statement before ROLLBACK lists every check: expected all pass = true.
-- An empty list, or any pass = false, is a FAILURE.

begin;

-- V0. Information (read-only): the distinct prog values on students.
select prog, count(*) as students from public.students group by prog order by prog nulls first;

-- V1. Shape: SECURITY DEFINER everywhere; internal functions closed to clients,
--     the public ones open to authenticated only. Expected: ok = true on every row.
select p.proname,
       p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       (case when p.proname like '\_%' or p.proname = 'trial_first_attended_on'
             then not has_function_privilege('authenticated', p.oid, 'execute')
             else has_function_privilege('authenticated', p.oid, 'execute') end
        and not has_function_privilege('anon', p.oid, 'execute')
        and (p.prosecdef or p.proname in ('_competition_eligible', '_competition_audience'))) as ok
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_competition_eligible','_competition_audience','trial_first_attended_on','_competition_period',
                     '_competition_scores','_competition_ranked','_competition_award_allowed','competition_standings',
                     'competition_unit_battle','competition_for_date','competition_award_add','competition_award_void',
                     'set_leaderboard_hidden','set_prize_eligible','trial_set_referrer','competition_finalize')
 order by p.proname;

create temp table _v149 (n numeric, test text, pass boolean, detail text) on commit drop;

-- Act as a user: claims + role, exactly as PostgREST sets them. Called while
-- still postgres; 'reset role' (inline) returns to postgres.
create function pg_temp.v_as(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;

do $$
declare
  ua uuid; ub uuid; cls uuid;
  u_admin uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_peer uuid := gen_random_uuid();
  u_par uuid := gen_random_uuid(); u_hid uuid := gen_random_uuid();
  ev uuid; m1 uuid; m2 uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid; s7 uuid; s8 uuid; k1 uuid;
  sv uuid; sc uuid; sh uuid; si uuid; sn uuid;
  b1 uuid; b2 uuid; b3 uuid; t1 uuid; t2 uuid; t3 uuid;
  a1 uuid; a2 uuid; v_ok boolean; v_txt text; v_err text; r record; n int; v_num numeric;
  syd constant text := 'Australia/Sydney';
begin
  select u.id into ua from public.units u order by u.name, u.id limit 1;
  select u.id into ub from public.units u order by u.name, u.id offset 1 limit 1;
  select c.id into cls from public.classes c order by c.id limit 1;
  if ua is null or ub is null or cls is null then
    raise exception 'V149 needs at least two units and one class';
  end if;

  -- callers: admin (owns unit A), staff (instructor), peer (adult member),
  -- parent (guardian of kid k1), hidden (adult member who hides)
  insert into auth.users (id, email) values
    (u_admin, 'zz149-admin@example.invalid'), (u_staff, 'zz149-staff@example.invalid'),
    (u_peer, 'zz149-peer@example.invalid'), (u_par, 'zz149-parent@example.invalid'),
    (u_hid, 'zz149-hidden@example.invalid');
  insert into public.users (id, email, full_name, role, status, unit_id) values
    (u_admin, 'zz149-admin@example.invalid',  'Zz149 Admin',  'student',    'approved', ua),
    (u_staff, 'zz149-staff@example.invalid',  'Zz149 Staff',  'instructor', 'approved', ua),
    (u_peer,  'zz149-peer@example.invalid',   'Zz149 Peer',   'student',    'approved', ua),
    (u_par,   'zz149-parent@example.invalid', 'Zz149 Parent', 'parent',     'approved', ua),
    (u_hid,   'zz149-hidden@example.invalid', 'Zz149 Hidden', 'student',    'approved', ua)
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, role = excluded.role,
                                 status = excluded.status, unit_id = excluded.unit_id;
  insert into public.unit_owners (unit_id, user_id) values (ua, u_admin) on conflict do nothing;

  -- students (unit A, adult unless noted)
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ana Alpha', 'Ana', 'Alpha', 'adult', ua, true, 'ok') returning id into s1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ben Beta', 'Ben', 'Beta', null, ua, true, 'ok') returning id into s2;          -- NULL prog = adult
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Cy Gamma', 'Cy', 'Gamma', 'adult', ua, true, 'ok') returning id into s3;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Di Delta', 'Di', 'Delta', 'adult', ua, true, 'ok') returning id into s4;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ed Eps', 'Ed', 'Eps', 'adult', ua, true, 'ok') returning id into s5;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Fi Zeta', 'Fi', 'Zeta', 'adult', ua, true, 'ok') returning id into s6;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz149 Gu Eta', 'Gu', 'Eta', 'adult', ua, true, 'ok', u_hid) returning id into s7;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, user_id)
    values ('Zz149 Hu Theta', 'Hu', 'Theta', 'adult', ua, true, 'ok', u_peer) returning id into s8;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Kit Zz149 Kappa', null, null, 'kids', ua, true, 'ok') returning id into k1;        -- names from full_name: Kit K.
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, membership_level)
    values ('Zz149 Vi Visitor', 'Vi', 'Visitor', 'adult', ua, true, 'ok', 'visitor_other_gym') returning id into sv;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, membership_level)
    values ('Zz149 Ca Casual', 'Ca', 'Casual', 'adult', ua, true, 'ok', 'casual_dropin') returning id into sc;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ho Hold', 'Ho', 'Hold', 'adult', ua, true, 'on_hold') returning id into sh;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 In Active', 'In', 'Active', 'adult', ua, false, 'ok') returning id into si;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing, membership_level)
    values ('Zz149 Nu Null', 'Nu', 'Null', 'adult', ua, true, 'ok', null) returning id into sn;
  insert into public.guardianships (student_id, guardian_user_id, status, origin, access)
    values (k1, u_par, 'active', 'legacy_sync', 'manage');

  -- attendance (July 2031)
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id) values
    (s1, '2031-07-05', 'beg', 'present', 1.00, 'gi',   ua),       -- test 1: same day, 1.00 + 0.50
    (s1, '2031-07-05', 'beg', 'present', 0.50, 'nogi', ua),
    (s2, '2031-07-06', 'private', 'present', 4, null, ua),        -- test 2: private 4 -> 1
    (s8, '2031-07-07', 'beg', 'present', 0.50, 'gi', ua),
    (k1, '2031-07-07', 'kids', 'present', 1.00, 'gi', ua),
    (sn, '2031-07-08', 'beg', 'present', 1.00, 'gi', ua), (sn, '2031-07-09', 'beg', 'present', 1.00, 'gi', ua),
    (sv, '2031-07-08', 'beg', 'present', 1.00, 'gi', ua), (sc, '2031-07-08', 'beg', 'present', 1.00, 'gi', ua),
    (sh, '2031-07-08', 'beg', 'present', 1.00, 'gi', ua), (si, '2031-07-08', 'beg', 'present', 1.00, 'gi', ua),
    (s1, '2031-07-09', 'beg', 'absent',  1.00, 'gi', ua),        -- not present: never counts
    (s1, '2031-06-30', 'beg', 'present', 1.00, 'gi', ua);        -- before the window: never counts
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id)
    select s7, d, 'beg', 'present', 1.00, 'gi', ua from generate_series(date '2031-07-10', date '2031-07-15', interval '1 day') d;   -- 6
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id)
    select s6, d, 'beg', 'present', 1.00, 'gi', ua from generate_series(date '2031-07-10', date '2031-07-14', interval '1 day') d;   -- 5
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id)
    values (s6, '2031-07-16', 'beg', 'present', 0.50, 'nogi', ua);                                                                   -- 5.5, 6 classes

  -- unit B adults: a full three-key tie at the top (same points, classes and
  -- last scored day), then one below it
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ty One', 'Ty', 'One', 'adult', ub, true, 'ok') returning id into t1;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ty Two', 'Ty', 'Two', 'adult', ub, true, 'ok') returning id into t2;
  insert into public.students (full_name, first_name, last_name, prog, unit_id, active, standing)
    values ('Zz149 Ty Three', 'Ty', 'Three', 'adult', ub, true, 'ok') returning id into t3;
  insert into public.attendance (student_id, class_date, class_type, status, class_value, modality, unit_id) values
    (t1, '2031-07-03', 'beg', 'present', 1.00, 'gi', ub), (t1, '2031-07-04', 'beg', 'present', 1.00, 'gi', ub),
    (t2, '2031-07-03', 'beg', 'present', 1.00, 'gi', ub), (t2, '2031-07-04', 'beg', 'present', 1.00, 'gi', ub),
    (t3, '2031-07-03', 'beg', 'present', 1.00, 'gi', ub);
  -- belt / degree, read back through the standings
  update public.students set belt = 'blue', degree = 2 where id = s1;
  update public.students set belt = 'grey/white', degree = 1 where id = k1;

  -- competitions: event E (July 2031), monthly M1 (like the seed), monthly M2 (with class_challenge)
  insert into public.competitions (name, kind, starts_on, ends_on, status) values ('Zz149 Event', 'event', '2031-07-01', '2031-07-31', 'active') returning id into ev;
  insert into public.competitions (name, kind, status) values ('Zz149 Monthly 1', 'monthly', 'draft') returning id into m1;
  insert into public.competitions (name, kind, status) values ('Zz149 Monthly 2', 'monthly', 'draft') returning id into m2;
  insert into public.competition_divisions (competition_id, unit_id, audience, label, sort)
    select c, u, a, 'Zz149 ' || a, 0 from unnest(array[ev, m1, m2]) c, unnest(array[ua, ub]) u, unnest(array['adult', 'kids']) a;
  insert into public.competition_rules (competition_id, rule_key, points, params) values
    (ev, 'class_attended', 1, '{"mode":"class_value","private_cap":1}'), (ev, 'social_post', 2, '{}'), (ev, 'class_challenge', 3, '{}'),
    (ev, 'referral_trial', 3, '{}'), (ev, 'referral_conversion', 5, '{}'),
    (m1, 'class_attended', 1, '{"mode":"class_value","private_cap":1}'), (m1, 'referral_trial', 3, '{}'), (m1, 'referral_conversion', 5, '{}'),
    (m2, 'class_attended', 1, '{"mode":"class_value","private_cap":1}'), (m2, 'class_challenge', 3, '{}');

  -- 1. two present classes on the same day: 1.00 + 0.50
  select * into r from public._competition_scores(ev, null, null) x where x.student_id = s1;
  insert into _v149 values (1, 'same day 1.00 + 0.50: class_points 1.5, classes_count 2', r.class_points = 1.5 and r.classes_count = 2,
    format('class_points %s, classes_count %s, gi %s, nogi %s', r.class_points, r.classes_count, r.gi_points, r.nogi_points));
  insert into _v149 values (1.1, 'gi / nogi split of the same sum', r.gi_points = 1.0 and r.nogi_points = 0.5,
    format('gi %s, nogi %s', r.gi_points, r.nogi_points));

  -- 2. private class_value 4 contributes private_cap 1
  select * into r from public._competition_scores(ev, null, null) x where x.student_id = s2;
  insert into _v149 values (2, 'private 4 counts 1 (mode class_value, private_cap 1); NULL modality only in class_points',
    r.class_points = 1 and r.gi_points = 0 and r.nogi_points = 0 and r.classes_count = 1,
    format('class_points %s, gi %s, nogi %s, classes %s', r.class_points, r.gi_points, r.nogi_points, r.classes_count));

  -- 3. social_post: one per student per day; voiding frees the day (admin)
  perform pg_temp.v_as(u_admin);
  a1 := public.competition_award_add(s3, 'social_post', '2031-07-06');
  begin
    perform public.competition_award_add(s3, 'social_post', '2031-07-06');
    v_err := 'second insert accepted';
  exception when unique_violation then v_err := 'unique_violation';
  end;
  perform public.competition_award_void(a1);
  a2 := public.competition_award_add(s3, 'social_post', '2031-07-06');
  execute 'reset role';
  insert into _v149 values (3, 'social_post twice same day: second fails; after void a new one is accepted',
    v_err = 'unique_violation' and a2 is not null and a2 <> a1, format('second insert: %s; new id after void: %s', v_err, a2 is not null));

  -- 4. social_post as non-admin staff fails; class_challenge as staff succeeds
  perform pg_temp.v_as(u_staff);
  begin
    perform public.competition_award_add(s3, 'social_post', '2031-07-07');
    v_err := 'accepted';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  -- a class award counts only with a present attendance for that class (152): mark it first.
  -- A quarter class (0.25), so Cy's points stay below Fi's and the ranks tested in 7 and 8 hold.
  insert into public.attendance (student_id, class_id, class_date, class_type, status, class_value, modality, unit_id)
    values (s3, cls, '2031-07-07', 'beg', 'present', 0.25, 'gi', ua);
  a1 := public.competition_award_add(s3, 'class_challenge', '2031-07-07', cls, '2031-07-07');
  execute 'reset role';
  select * into r from public._competition_scores(ev, null, null) x where x.student_id = s3;
  insert into _v149 values (4, 'social_post by staff refused; class_challenge by staff accepted (award_points 2 + 3)',
    v_err = 'insufficient_privilege' and a1 is not null and r.award_points = 5,
    format('social_post by staff: %s; challenge id: %s; award_points %s', v_err, a1 is not null, r.award_points));

  -- 5. an award outside the event window: not in the event; in a monthly race
  --    only when that race has the rule (social_post never in M1/M2)
  perform pg_temp.v_as(u_admin);
  perform public.competition_award_add(s4, 'social_post', '2031-08-10');
  execute 'reset role';
  perform pg_temp.v_as(u_staff);
  -- present for that class first (152)
  insert into public.attendance (student_id, class_id, class_date, class_type, status, class_value, modality, unit_id)
    values (s4, cls, '2031-08-11', 'beg', 'present', 1.00, 'gi', ua);
  perform public.competition_award_add(s4, 'class_challenge', '2031-08-11', cls, '2031-08-11');
  execute 'reset role';
  select string_agg(format('%s=%s', x.k, x.v), ' ' order by x.k) into v_txt
    from (select 'E' as k, (select award_points from public._competition_scores(ev, null, null) where student_id = s4) as v
          union all select 'M1aug', (select award_points from public._competition_scores(m1, '2031-08-01', '2031-08-31') where student_id = s4)
          union all select 'M2aug', (select award_points from public._competition_scores(m2, '2031-08-01', '2031-08-31') where student_id = s4)
          union all select 'M2sep', (select award_points from public._competition_scores(m2, '2031-09-01', '2031-09-30') where student_id = s4)) x;
  insert into _v149 values (5, 'award outside the window: E 0; M1 (no award rules) 0; M2 (class_challenge only) 3 in its month, 0 the next',
    v_txt = 'E=0 M1aug=0 M2aug=3 M2sep=0', v_txt);

  -- 6. referrals (staff sets the referrer through the RPC)
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                     attended_at, converted_at)
    values (ua, 'Re', 'Zz149', 'zz149-b1@example.invalid', '0400000149', 'booked', now(), cls, '2031-06-01', '18:00',
            timestamp '2031-06-01 19:00' at time zone syd, timestamp '2031-07-20 10:00' at time zone syd) returning id into b1;
  insert into public.trial_sessions (trial_booking_id, class_id, class_date, class_time, attended) values
    (b1, cls, '2031-06-20', '18:00', false),
    (b1, cls, '2031-07-10', '18:00', true);                       -- sessions win over the legacy attended_at (1 Jun)
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                     attended_at, converted_at, converted_student_id)
    values (ua, 'Se', 'Zz149', 'zz149-b2@example.invalid', '0400000150', 'booked', now(), cls, '2031-07-12', '18:00',
            timestamp '2031-07-12 19:00' at time zone syd, timestamp '2031-07-15 10:00' at time zone syd, s5) returning id into b2;
  insert into public.trial_bookings (unit_id, first_name, last_name, email, phone, trial_status, booked_at, class_id, class_date, class_time,
                                     attended_at)
    values (ua, 'Le', 'Zz149', 'zz149-b3@example.invalid', '0400000151', 'booked', now(), cls, '2031-07-05', '18:00',
            timestamp '2031-07-05 19:00' at time zone syd) returning id into b3;   -- no sessions: legacy path
  perform pg_temp.v_as(u_peer);
  begin
    perform public.trial_set_referrer(b1, s5);
    v_err := 'accepted';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  execute 'reset role';
  perform pg_temp.v_as(u_staff);
  perform public.trial_set_referrer(b1, s5);
  perform public.trial_set_referrer(b2, s5);   -- converted into the referrer: never counts
  execute 'reset role';
  select * into r from public._competition_scores(ev, null, null) x where x.student_id = s5;
  insert into _v149 values (6, 'referral: trial attended in window 3 + converted in window 5; converted = referrer 0',
    r.referral_points = 8, format('referral_points %s', r.referral_points));
  insert into _v149 values (6.1, 'trial_set_referrer: member refused, staff stamps set_by / set_at',
    v_err = 'insufficient_privilege'
    and exists (select 1 from public.trial_bookings tb where tb.id = b1 and tb.referred_by_set_by = u_staff and tb.referred_by_set_at is not null),
    format('member: %s', v_err));
  insert into _v149 values (6.2, 'trial_first_attended_on: sessions path (10 Jul, not legacy 1 Jun); no-sessions path (5 Jul)',
    public.trial_first_attended_on(b1) = date '2031-07-10' and public.trial_first_attended_on(b3) = date '2031-07-05',
    format('b1 %s, b3 %s', public.trial_first_attended_on(b1), public.trial_first_attended_on(b3)));

  -- 7. prize_rank skips a prize_eligible = false student; rank keeps them in place
  perform pg_temp.v_as(u_staff);
  begin
    perform public.set_prize_eligible(s6, false);
    v_err := 'accepted';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  execute 'reset role';
  perform pg_temp.v_as(u_admin);
  perform public.set_prize_eligible(s6, false);
  execute 'reset role';
  select string_agg(format('%s:%s/%s', x.who, x.rank, coalesce(x.prize_rank::text, '-')), ' ' order by x.rank, x.who) into v_txt
    from (select case r2.student_id when s5 then 'Ed' when s7 then 'Gu' when s6 then 'Fi' when s3 then 'Cy' when sn then 'Nu' end as who, r2.rank, r2.prize_rank
            from public._competition_ranked(ev, null, null) r2
           where r2.student_id in (s5, s7, s6, s3, sn)) x;
  insert into _v149 values (7, 'rank keeps Fi (prize_eligible false) at 3; prize_rank skips Fi; staff cannot set it',
    v_txt = 'Ed:1/1 Gu:2/2 Fi:3/- Cy:4/3 Nu:5/4' and v_err = 'insufficient_privilege', v_txt || '; staff: ' || v_err);

  -- 7.1 standard competition ranking: a full tie shares 1, the next is 3
  select string_agg(format('%s:%s/%s', case x.student_id when t1 then 'T1' when t2 then 'T2' else 'T3' end, x.rank, x.prize_rank), ' '
                    order by x.rank, case x.student_id when t1 then 1 when t2 then 2 else 3 end) into v_txt
    from public._competition_ranked(ev, null, null) x where x.student_id in (t1, t2, t3);
  insert into _v149 values (7.1, 'full three-key tie at the top: both rank 1 (prize 1), the next rank 3 (prize 3)',
    v_txt = 'T1:1/1 T2:1/1 T3:3/3', v_txt);

  -- 7.2 class award with no class_id (a one-off class): once per day
  perform pg_temp.v_as(u_staff);
  a1 := public.competition_award_add(s3, 'class_challenge', '2031-09-05', null, '2031-09-05');
  begin
    perform public.competition_award_add(s3, 'class_challenge', '2031-09-05', null, '2031-09-05');
    v_err := 'accepted';
  exception when unique_violation then v_err := 'unique_violation';
  end;
  begin
    perform public.competition_award_add(s3, 'class_challenge', '2031-09-06', gen_random_uuid(), null);
    v_txt := 'accepted';
  exception when invalid_parameter_value then v_txt := 'invalid_parameter_value';
  end;
  execute 'reset role';
  insert into _v149 values (7.2, 'class award with NULL class_id accepted once per day, second refused; no class_date refused',
    a1 is not null and v_err = 'unique_violation' and v_txt = 'invalid_parameter_value', format('second: %s; no date: %s', v_err, v_txt));

  -- 8. hidden student (Gu hides himself through the RPC)
  perform pg_temp.v_as(u_hid);
  perform public.set_leaderboard_hidden(s7, true);
  execute 'reset role';
  perform pg_temp.v_as(u_peer);
  select count(*) filter (where x.student_id = s7), max(x.rank) filter (where x.student_id = s6) into n, v_num
    from public.competition_standings(ev) x;
  execute 'reset role';
  insert into _v149 values (8, 'hidden: absent for a peer; the peer still sees Fi at her real rank 3',
    n = 0 and v_num = 3, format('Gu rows for peer %s, Fi rank for peer %s', n, v_num));
  perform pg_temp.v_as(u_hid);
  select count(*) into n from public.competition_standings(ev) x where x.student_id = s7 and x.rank = 2;
  execute 'reset role';
  v_ok := (n = 1);
  perform pg_temp.v_as(u_staff);
  select count(*) into n from public.competition_standings(ev) x where x.student_id = s7 and x.rank = 2;
  execute 'reset role';
  insert into _v149 values (8.1, 'hidden: present for self and for staff (rank 2)', v_ok and n = 1, format('self %s, staff %s', v_ok, n));

  -- 9. kids divisions
  perform pg_temp.v_as(u_peer);
  select count(*) into n from public.competition_standings(ev) x where x.audience = 'kids';
  execute 'reset role';
  insert into _v149 values (9, 'kids division: none for an adult with no kids', n = 0, format('kids rows for peer: %s', n));
  perform pg_temp.v_as(u_par);
  select count(*), count(*) filter (where x.student_id = k1), bool_and(x.unit_id = ua),
         max(x.display_name) filter (where x.student_id = k1)
    into n, v_num, v_ok, v_txt
    from public.competition_standings(ev) x where x.audience = 'kids';
  execute 'reset role';
  insert into _v149 values (9.1, 'kids division: returned to a guardian of a kid in it (unit A only), name "Kit K."',
    n >= 1 and v_num = 1 and v_ok and v_txt = 'Kit K.', format('kids rows %s, kid rows %s, all unit A %s, name %s', n, v_num, v_ok, v_txt));

  -- 10. eligibility
  select string_agg(x.who, ',' order by x.who) into v_txt
    from (select case s.student_id when sv then 'visitor' when sc then 'casual' when sh then 'on_hold' when si then 'inactive' when sn then 'null_level' end as who
            from public._competition_scores(ev, null, null) s
           where s.student_id in (sv, sc, sh, si, sn)) x;
  insert into _v149 values (10, 'visitor_% / casual_% / on_hold / inactive absent; NULL membership_level present',
    v_txt = 'null_level', coalesce(v_txt, '(none)'));

  -- 11. unit battle
  perform pg_temp.v_as(u_peer);
  select bool_and(case when b.active_students = 0 then b.avg_classes = 0
                       else b.avg_classes = b.total_classes::numeric / b.active_students end),
         max(format('%s/%s/%s', b.active_students, b.total_classes, round(b.avg_classes, 4))) filter (where b.unit_id = ua and b.audience = 'adult'),
         max(format('%s/%s/%s', b.active_students, b.total_classes, round(b.avg_classes, 4))) filter (where b.unit_id = ua and b.audience = 'kids'),
         count(*)
    into v_ok, v_txt, v_err, n
    from public.competition_unit_battle(ev) b;
  execute 'reset role';
  -- (Cy's quarter class for her challenge in 4 makes her active: 7 / 19, not 6 / 18)
  insert into _v149 values (11, 'unit battle: avg = total / active (0 when none); unit A adults 7 active / 19 classes / 2.7143; kids 1 / 1 / 1',
    v_ok and v_txt = '7/19/2.7143' and v_err = '1/1/1.0000' and n = 4, format('A adult %s, A kids %s, rows %s', v_txt, v_err, n));

  -- finalize: admin only; one row per ranked student, hidden included
  perform pg_temp.v_as(u_staff);
  begin
    perform public.competition_finalize(ev, null, null);
    v_err := 'accepted';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  execute 'reset role';
  perform pg_temp.v_as(u_admin);
  n := public.competition_finalize(ev, null, null);
  execute 'reset role';
  insert into _v149 values (12.1, 'competition_finalize: staff refused; admin snapshots every ranked row (Gu included, rank 2)',
    v_err = 'insufficient_privilege'
    and n = (select count(*) from public._competition_ranked(ev, null, null))
    and exists (select 1 from public.competition_results cr where cr.competition_id = ev and cr.student_id = s7 and cr.rank = 2
                  and cr.period_from = '2031-07-01' and cr.period_to = '2031-07-31'),
    format('staff: %s; rows %s', v_err, n));

  -- 12.3 finalize REPLACES the period: a student made ineligible loses the row
  update public.students set standing = 'on_hold' where id = s1;
  perform pg_temp.v_as(u_admin);
  n := public.competition_finalize(ev, null, null);
  execute 'reset role';
  insert into _v149 values (12.3, 'finalize again after Ana goes on hold: her row is gone, the snapshot equals the new ranking',
    not exists (select 1 from public.competition_results cr where cr.competition_id = ev and cr.student_id = s1)
    and n = (select count(*) from public.competition_results cr where cr.competition_id = ev
               and cr.period_from = '2031-07-01' and cr.period_to = '2031-07-31')
    and n = (select count(*) from public._competition_ranked(ev, null, null)),
    format('rows written %s', n));
  update public.students set standing = 'ok' where id = s1;

  -- 12.4 belt and degree come back for an adult and a kid
  perform pg_temp.v_as(u_staff);
  select string_agg(format('%s=%s/%s', case x.student_id when s1 then 'adult' else 'kid' end, x.belt, x.degree), ' '
                    order by case x.student_id when s1 then 1 else 2 end) into v_txt
    from public.competition_standings(ev) x where x.student_id in (s1, k1);
  execute 'reset role';
  insert into _v149 values (12.4, 'standings return belt and degree (adult blue/2, kid grey/white/1)',
    v_txt = 'adult=blue/2 kid=grey/white/1', v_txt);

  -- a caller who is not approved gets nothing
  update public.users set status = 'pending' where id = u_peer;
  perform pg_temp.v_as(u_peer);
  begin
    perform 1 from public.competition_standings(ev);
    v_err := 'returned rows';
  exception when insufficient_privilege then v_err := 'insufficient_privilege';
  end;
  execute 'reset role';
  insert into _v149 values (12.2, 'standings refused to a caller who is not approved', v_err = 'insufficient_privilege', v_err);
end $$;

-- THE RESULT: every row pass = true. Empty = failure.
select n, test, pass, detail from _v149 order by n;

rollback;
