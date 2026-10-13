-- 146_mia_resume_clock_verify.sql
--
-- V1 is read-only. V2 is one DO block that ENDS WITH RAISE EXCEPTION carrying
-- its results: the "ERROR:  V146 ..." message IS the report, and nothing in the
-- block persists. Synthetic members only, in July 2031, with no unit (never held
-- by the unit gate) and throwaway addresses, so real rows never interfere.
-- Expected: every line "pass".

-- ---------------------------------------------------------------------------
-- V1. The column is the LAST column of students; the trigger exists.
--     Expected: is_last t, trigger_present t.
-- ---------------------------------------------------------------------------
select (select a.attname from pg_attribute a
         where a.attrelid = 'public.students'::regclass and a.attnum > 0 and not a.attisdropped
         order by a.attnum desc limit 1) = 'mia_resume_at' as is_last,
       exists (select 1 from pg_trigger t
                where t.tgrelid = 'public.students'::regclass and t.tgname = 'trg_students_mia_resume'
                  and not t.tgisinternal) as trigger_present;

-- ---------------------------------------------------------------------------
-- V2. Cases a-f (rolled back).
-- ---------------------------------------------------------------------------
do $$
declare
  out text := ''; v text; st uuid; ok boolean;
  syd constant text := 'Australia/Sydney';
begin
  -- the 143 defaults, whatever is live (same pin as 143's verify; the final
  -- RAISE EXCEPTION rolls this back, so production's tuned values are untouched)
  update public.mia_settings set settle_days = 2, gate_lookback_days = 3, gate_min_ratio = 0.5,
                                 gate_baseline_weeks = 6, max_late_days = 7 where id;
  update public.mia_codes set days = case code when 'M1' then 10 when 'M2' then 14 when 'M3' then 21 else 30 end,
                              seq  = case code when 'M1' then 1 when 'M2' then 2 when 'M3' then 3 else 4 end;

  -- helper as a local SQL expression via a temp function
  create function pg_temp.v146_due(p_st uuid, p_day date) returns text language sql stable as $f$
    select coalesce(string_agg(c.code || '@' || split_part(c.period_key, ':', 2), ',' order by c.code), '-')
      from public.mia_email_candidates((p_day + time '15:30') at time zone 'Australia/Sydney') c
     where c.student_id = p_st
  $f$;

  -- a. on hold 30 days (last class 1 Jun), released 1 Jul 10:00, no class since
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 a', 'Zz', 'A', 'adult', 'zz-v146-a@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-01', 'beg');
  update public.students set mia_resume_at = (timestamp '2031-07-01 10:00' at time zone syd) where id = st;
  v := pg_temp.v146_due(st, '2031-07-01') || ' | ' || pg_temp.v146_due(st, '2031-07-11') || ' | '
    || pg_temp.v146_due(st, '2031-07-12') || ' | ' || pg_temp.v146_due(st, '2031-07-13');
  out := out || format(E'\n  a off hold: release day | +10 | +11 | +12 = %s -> %s', v,
    case when v = '- | - | - | M1@2031-07-01' then 'pass' else 'FAIL (expected - | - | - | M1@2031-07-01)' end);
  select c.last_class_date::text || '/' || c.days_absent into v
    from public.mia_email_candidates((date '2031-07-13' + time '15:30') at time zone syd) c where c.student_id = st;
  out := out || format(E'\n  a   M1 row shows the real last class / days since it = %s -> %s', v,
    case when v = '2031-06-01/42' then 'pass' else 'FAIL (expected 2031-06-01/42)' end);
  v := pg_temp.v146_due(st, '2031-07-17');
  out := out || format(E'\n  a   +16 (M2 due, M1 superseded) = %s -> %s', v,
    case when v = 'M2@2031-07-01' then 'pass' else 'FAIL (expected M2@2031-07-01)' end);

  -- b. same, but back in class at +5 (6 Jul): never an M1 for the release episode, no R
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 b', 'Zz', 'B', 'adult', 'zz-v146-b@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-01', 'beg');
  update public.students set mia_resume_at = (timestamp '2031-07-01 10:00' at time zone syd) where id = st;
  insert into public.attendance (student_id, status, class_date, class_type, confirmed_at)
    values (st, 'present', '2031-07-06', 'beg', timestamp '2031-07-06 20:00' at time zone syd);
  v := pg_temp.v146_due(st, '2031-07-07') || ' | ' || pg_temp.v146_due(st, '2031-07-13') || ' | '
    || pg_temp.v146_due(st, '2031-07-17') || ' | ' || pg_temp.v146_due(st, '2031-07-18');
  out := out || format(E'\n  b back at +5: +6 | +12 | new ep +11 | new ep +12 = %s -> %s', v,
    case when v = '- | - | - | M1@2031-07-06' then 'pass' else 'FAIL (expected - | - | - | M1@2031-07-06)' end);

  -- c. reactivated (active false -> true) after 40 days: last class 1 Jun, reactivated 11 Jul
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 c', 'Zz', 'C', 'adult', 'zz-v146-c@example.invalid', false, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-01', 'beg');
  update public.students set active = true where id = st;                      -- the trigger stamps now() ...
  ok := (select s.mia_resume_at is not null from public.students s where s.id = st);
  update public.students set mia_resume_at = (timestamp '2031-07-11 09:00' at time zone syd) where id = st;  -- ... moved to the scenario's day
  v := pg_temp.v146_due(st, '2031-07-11') || ' | ' || pg_temp.v146_due(st, '2031-07-21') || ' | '
    || pg_temp.v146_due(st, '2031-07-22') || ' | ' || pg_temp.v146_due(st, '2031-07-23');
  out := out || format(E'\n  c reactivated: day | +10 | +11 | +12 = %s, stamped by trigger %s -> %s', v, ok,
    case when v = '- | - | - | M1@2031-07-11' and ok then 'pass' else 'FAIL (expected - | - | - | M1@2031-07-11, stamped)' end);

  -- d. never on hold: exactly 143/144's schedule (M1 at last + 12, M2 at last + 16)
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 d', 'Zz', 'D', 'adult', 'zz-v146-d@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  v := pg_temp.v146_due(st, '2031-07-12') || ' | ' || pg_temp.v146_due(st, '2031-07-13') || ' | '
    || pg_temp.v146_due(st, '2031-07-16') || ' | ' || pg_temp.v146_due(st, '2031-07-17');
  out := out || format(E'\n  d never on hold: +11 | +12 | +15 | +16 = %s -> %s', v,
    case when v = '- | M1@2031-07-01 | M1@2031-07-01 | M2@2031-07-01' then 'pass'
         else 'FAIL (expected - | M1@2031-07-01 | M1@2031-07-01 | M2@2031-07-01)' end);
  select c.last_class_date::text || '/' || c.days_absent into v
    from public.mia_email_candidates((date '2031-07-13' + time '15:30') at time zone syd) c where c.student_id = st;
  out := out || format(E'\n  d   last class / days = %s -> %s', v, case when v = '2031-07-01/12' then 'pass' else 'FAIL' end);

  -- e. last class AFTER an old release: the anchor is the class
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 e', 'Zz', 'E', 'adult', 'zz-v146-e@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-01', 'beg');
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-10', 'beg');
  update public.students set mia_resume_at = (timestamp '2031-07-01 10:00' at time zone syd) where id = st;
  v := pg_temp.v146_due(st, '2031-07-13') || ' | ' || pg_temp.v146_due(st, '2031-07-21') || ' | ' || pg_temp.v146_due(st, '2031-07-22');
  out := out || format(E'\n  e class after release: release+12 | class+11 | class+12 = %s -> %s', v,
    case when v = '- | - | M1@2031-07-10' then 'pass' else 'FAIL (expected - | - | M1@2031-07-10)' end);

  -- g. R unchanged for a member never on hold: M1 sent, back in class -> R the day after
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v146 g', 'Zz', 'G', 'adult', 'zz-v146-g@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  insert into public.email_sends (kind, period_key, student_id, recipient_email, status, sent_at)
    values ('mia', st::text || ':2031-07-01:M1', st, 'zz-v146-g@example.invalid', 'sent', timestamp '2031-07-13 15:00' at time zone syd);
  insert into public.attendance (student_id, status, class_date, class_type, confirmed_at)
    values (st, 'present', '2031-07-15', 'beg', timestamp '2031-07-15 20:00' at time zone syd);
  v := pg_temp.v146_due(st, '2031-07-16');
  out := out || format(E'\n  g R after a sent M1 (never on hold) = %s -> %s', v,
    case when v = 'R@2031-07-01' then 'pass' else 'FAIL (expected R@2031-07-01)' end);

  -- h. trial class recorded on the student on day 0 (1 Jul), converted day 20 (21 Jul), no class since:
  --    nothing until conversion + 12 (2 Aug), then M1 on the conversion episode
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing, converted_at)
    values ('zz v146 h', 'Zz', 'H', 'adult', 'zz-v146-h@example.invalid', true, 'ok', timestamp '2031-07-21 11:00' at time zone syd)
    returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  v := pg_temp.v146_due(st, '2031-07-13') || ' | ' || pg_temp.v146_due(st, '2031-07-21') || ' | '
    || pg_temp.v146_due(st, '2031-08-01') || ' | ' || pg_temp.v146_due(st, '2031-08-02');
  out := out || format(E'\n  h converted 20 days after the trial class: trial+12 | conv day | conv+11 | conv+12 = %s -> %s', v,
    case when v = '- | - | - | M1@2031-07-21' then 'pass' else 'FAIL (expected - | - | - | M1@2031-07-21)' end);
  select c.last_class_date::text || '/' || c.days_absent into v
    from public.mia_email_candidates((date '2031-08-02' + time '15:30') at time zone syd) c where c.student_id = st;
  out := out || format(E'\n  h   M1 row shows the real last class / days since it = %s -> %s', v,
    case when v = '2031-07-01/32' then 'pass' else 'FAIL (expected 2031-07-01/32)' end);

  -- i. converted day 0 (1 Jul), attends day 3 (4 Jul): the anchor is the class (normal)
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing, converted_at)
    values ('zz v146 i', 'Zz', 'I', 'adult', 'zz-v146-i@example.invalid', true, 'ok', timestamp '2031-07-01 11:00' at time zone syd)
    returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-28', 'beg');
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-04', 'beg');
  v := pg_temp.v146_due(st, '2031-07-13') || ' | ' || pg_temp.v146_due(st, '2031-07-15') || ' | ' || pg_temp.v146_due(st, '2031-07-16');
  out := out || format(E'\n  i converted then trained day 3: conv+12 | class+11 | class+12 = %s -> %s', v,
    case when v = '- | - | M1@2031-07-04' then 'pass' else 'FAIL (expected - | - | M1@2031-07-04)' end);

  -- f. the trigger
  insert into public.students (full_name, first_name, prog, email, active, standing)
    values ('zz v146 f', 'Zz', 'adult', 'zz-v146-f@example.invalid', true, 'on_hold') returning id into st;
  update public.students set standing = 'ok' where id = st;
  ok := (select s.mia_resume_at is not null and s.mia_resume_at >= now() - interval '1 minute' from public.students s where s.id = st);
  out := out || format(E'\n  f1 on_hold -> ok sets mia_resume_at: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set mia_resume_at = null where id = st;
  update public.students set standing = 'on_hold' where id = st;
  ok := (select s.mia_resume_at is null from public.students s where s.id = st);
  out := out || format(E'\n  f2 ok -> on_hold leaves it: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set standing = 'on_hold' where id = st;
  ok := (select s.mia_resume_at is null from public.students s where s.id = st);
  out := out || format(E'\n  f3 on_hold -> on_hold leaves it: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set standing = 'ok' where id = st;
  update public.students set mia_resume_at = null where id = st;
  update public.students set active = false where id = st;
  ok := (select s.mia_resume_at is null from public.students s where s.id = st);
  out := out || format(E'\n  f4 active true -> false leaves it: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set full_name = 'zz v146 f renamed' where id = st;
  ok := (select s.mia_resume_at is null from public.students s where s.id = st);
  out := out || format(E'\n  f5 unrelated column update leaves it: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set active = true where id = st;
  ok := (select s.mia_resume_at is not null from public.students s where s.id = st);
  out := out || format(E'\n  f6 active false -> true sets it: %s', case when ok then 'pass' else 'FAIL' end);
  update public.students set mia_resume_at = timestamptz '2031-01-01 00:00+00' where id = st;
  update public.students set standing = 'ok', active = true where id = st;   -- no transition
  ok := (select s.mia_resume_at = timestamptz '2031-01-01 00:00+00' from public.students s where s.id = st);
  out := out || format(E'\n  f7 standing/active in SET but unchanged leaves it: %s', case when ok then 'pass' else 'FAIL' end);

  raise exception 'V146 results (rolled back):%', out;
end $$;
