-- 152_competitions_award_presence_verify.sql
--
-- Run AFTER 152, with psql (ON_ERROR_STOP), e.g.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/152_competitions_award_presence_verify.sql
-- One transaction ending in ROLLBACK: nothing persists. Every test prints
-- "PASS ..." (NOTICE); the first failure stops it with "FAIL ...".
-- Uses its own temporary competition, division and rules in July 2031, an
-- existing active eligible student, and two existing classes.

begin;

do $$
declare
  st record; cx uuid; cy uuid; comp uuid; att uuid; v numeric; n int; res text;
  -- 149's return columns, exactly (152 must not change them)
  expected constant text := 'TABLE(division_id uuid, unit_id uuid, audience text, student_id uuid, display_name text, photo_url text, points numeric, class_points numeric, gi_points numeric, nogi_points numeric, award_points numeric, referral_points numeric, classes_count integer, last_scored_on date, prize_eligible boolean, leaderboard_hidden boolean, belt text, degree integer)';
begin
  -- 0. no social_post award carries a class_date (the rule leaves those alone)
  select count(*) into n from public.competition_awards where award_key = 'social_post' and class_date is not null;
  if n <> 0 then raise exception 'FAIL 0: % social_post award(s) have class_date set', n; end if;
  raise notice 'PASS 0: no social_post award has class_date set';

  select s.id, s.unit_id into st
    from public.students s
   where public._competition_eligible(s.active, s.standing::text, s.membership_level::text) and s.unit_id is not null
   order by s.id limit 1;
  select c.id into cx from public.classes c order by c.id limit 1;
  select c.id into cy from public.classes c order by c.id offset 1 limit 1;
  if st.id is null or cx is null or cy is null then
    raise exception 'FAIL setup: needs one active eligible student and two classes';
  end if;

  insert into public.competitions (name, kind, starts_on, ends_on, status)
    values ('zz152 verify', 'event', '2031-07-01', '2031-07-31', 'draft') returning id into comp;
  -- both boards of the unit, so the student lands on theirs whichever rule decides it (156: belt)
  insert into public.competition_divisions (competition_id, unit_id, audience, label) values
    (comp, st.unit_id, 'adult', 'zz152 adults'), (comp, st.unit_id, 'kids', 'zz152 kids');
  insert into public.competition_rules (competition_id, rule_key, points, params, enabled) values
    (comp, 'class_attended', 1, '{"mode":"class_value","private_cap":1}', true),
    (comp, 'class_challenge', 3, '{}', true),
    (comp, 'social_post', 2, '{}', true);

  -- 1. present attendance + award: the rule's points
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (st.id, cx, '2031-07-05', '18:00', 'beg', 'present', 1.00, st.unit_id) returning id into att;
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (st.id, 'class_challenge', '2031-07-05', cx, '2031-07-05');
  select x.award_points into v from public._competition_scores(comp, '2031-07-05', '2031-07-05') x where x.student_id = st.id;
  if v is distinct from 3 then raise exception 'FAIL 1: present + award gave %, expected 3', v; end if;
  raise notice 'PASS 1: present attendance + award = 3';

  -- 2. the same attendance marked absent: 0
  update public.attendance set status = 'absent' where id = att;
  select x.award_points into v from public._competition_scores(comp, '2031-07-05', '2031-07-05') x where x.student_id = st.id;
  if v is distinct from 0 then raise exception 'FAIL 2: absent gave %, expected 0', v; end if;
  raise notice 'PASS 2: attendance absent = 0';

  -- 3. the attendance removed: 0
  delete from public.attendance where id = att;
  select x.award_points into v from public._competition_scores(comp, '2031-07-05', '2031-07-05') x where x.student_id = st.id;
  if v is distinct from 0 then raise exception 'FAIL 3: no attendance gave %, expected 0', v; end if;
  raise notice 'PASS 3: attendance deleted = 0';

  -- 4. present again: the award counts again (the award row was never touched)
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (st.id, cx, '2031-07-05', '18:00', 'beg', 'present', 1.00, st.unit_id);
  select x.award_points into v from public._competition_scores(comp, '2031-07-05', '2031-07-05') x where x.student_id = st.id;
  if v is distinct from 3 then raise exception 'FAIL 4: present again gave %, expected 3', v; end if;
  select count(*) into n from public.competition_awards w where w.student_id = st.id and w.class_date = '2031-07-05' and w.voided_at is null;
  if n <> 1 then raise exception 'FAIL 4: the award row changed (% live rows)', n; end if;
  raise notice 'PASS 4: present again = 3, award row untouched';

  -- 5. award for class X, present at class Y the same day: 0
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (st.id, cy, '2031-07-06', '19:00', 'beg', 'present', 1.00, st.unit_id);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (st.id, 'class_challenge', '2031-07-06', cx, '2031-07-06');
  select x.award_points into v from public._competition_scores(comp, '2031-07-06', '2031-07-06') x where x.student_id = st.id;
  if v is distinct from 0 then raise exception 'FAIL 5: class mismatch gave %, expected 0', v; end if;
  raise notice 'PASS 5: award class X, present at class Y = 0';

  -- 6. one-off class: both class_id NULL, same date: counts
  insert into public.attendance (student_id, class_id, class_date, class_time, class_type, status, class_value, unit_id)
    values (st.id, null, '2031-07-07', '10:00', 'beg', 'present', 1.00, st.unit_id);
  insert into public.competition_awards (student_id, award_key, award_date, class_id, class_date)
    values (st.id, 'class_challenge', '2031-07-07', null, '2031-07-07');
  select x.award_points into v from public._competition_scores(comp, '2031-07-07', '2031-07-07') x where x.student_id = st.id;
  if v is distinct from 3 then raise exception 'FAIL 6: one-off gave %, expected 3', v; end if;
  raise notice 'PASS 6: one-off (class_id NULL both sides) = 3';

  -- 7. social_post with no attendance at all: still counts
  insert into public.competition_awards (student_id, award_key, award_date) values (st.id, 'social_post', '2031-07-08');
  select x.award_points into v from public._competition_scores(comp, '2031-07-08', '2031-07-08') x where x.student_id = st.id;
  if v is distinct from 2 then raise exception 'FAIL 7: social_post gave %, expected 2', v; end if;
  raise notice 'PASS 7: social_post without attendance = 2';

  -- 8. signature and return columns identical to 149
  res := pg_get_function_result('public._competition_scores(uuid, date, date)'::regprocedure);
  -- 156 appends minor as the LAST column, 163 then checkin_points; everything before stays 149's
  if res is distinct from expected and res is distinct from replace(expected, 'degree integer)', 'degree integer, minor boolean)')
     and res is distinct from replace(expected, 'degree integer)', 'degree integer, minor boolean, checkin_points numeric)') then
    raise exception 'FAIL 8: return columns changed: %', res;
  end if;
  if pg_get_function_identity_arguments('public._competition_scores(uuid, date, date)'::regprocedure) <> 'p_competition uuid, p_from date, p_to date' then
    raise exception 'FAIL 8: arguments changed';
  end if;
  raise notice 'PASS 8: signature and return columns identical to 149';
end $$;

rollback;
