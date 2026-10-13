-- 147_mia_never_step_back_verify.sql
--
-- One DO block that ENDS WITH RAISE EXCEPTION carrying its results: the
-- "ERROR:  V147 ..." message IS the report, and nothing in the block persists
-- (the factory schedule pin included: production's tuned values are untouched).
-- Synthetic members only, July/August 2031, no unit, throwaway addresses.
-- Factory schedule pinned: M1 10, M2 14, M3 21, M4/T4 30, settle 2, max late 7,
-- so for a last class on 1 Jul: M1 13 Jul, M2 17 Jul, M3 24 Jul, M4+T4 2 Aug.
-- Expected: every line "pass".

do $$
declare
  out text := ''; v text; st uuid;
  syd constant text := 'Australia/Sydney';
begin
  -- the 143 defaults, whatever is live (same pin as 143's / 146's verify)
  update public.mia_settings set settle_days = 2, gate_lookback_days = 3, gate_min_ratio = 0.5,
                                 gate_baseline_weeks = 6, max_late_days = 7 where id;
  update public.mia_codes set days = case code when 'M1' then 10 when 'M2' then 14 when 'M3' then 21 else 30 end,
                              seq  = case code when 'M1' then 1 when 'M2' then 2 when 'M3' then 3 else 4 end;

  create function pg_temp.v147_due(p_st uuid, p_day date) returns text language sql stable as $f$
    select coalesce(string_agg(c.code || '@' || split_part(c.period_key, ':', 2) || '>' || c.recipient, ',' order by c.code, c.recipient), '-')
      from public.mia_email_candidates((p_day + time '15:30') at time zone 'Australia/Sydney') c
     where c.student_id = p_st
  $f$;
  create function pg_temp.v147_sent(p_st uuid, p_ep text, p_code text, p_to text, p_status text default 'sent', p_err text default null)
  returns void language sql as $f$
    insert into public.email_sends (kind, period_key, student_id, recipient_email, status, error, sent_at)
    values ('mia', p_st::text || ':' || p_ep || ':' || p_code, p_st, p_to, p_status, p_err,
            case when p_status = 'sent' then now() end)
  $f$;

  -- a. M2 already sent (old schedule), M1 due now under the current one -> not returned
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 a', 'Zz', 'A', 'adult', 'zz-v147-a@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M2', 'zz-v147-a@example.invalid');
  v := pg_temp.v147_due(st, '2031-07-13');
  out := out || format(E'\n  a M2 sent, M1 due (+12) = %s -> %s', v, case when v = '-' then 'pass' else 'FAIL (expected -)' end);

  -- b. M3 sent: M2 due later -> not returned; M4 (+T4) later -> returned
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 b', 'Zz', 'B', 'adult', 'zz-v147-b@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M3', 'zz-v147-b@example.invalid');
  v := pg_temp.v147_due(st, '2031-07-17') || ' | ' || pg_temp.v147_due(st, '2031-08-02');
  out := out || format(E'\n  b M3 sent: M2 due (+16) | M4 due (+32) = %s -> %s', v,
    case when v = '- | M4@2031-07-01>zz-v147-b@example.invalid,T4@2031-07-01>info@mybjj.com.au' then 'pass'
         else 'FAIL (expected - | M4..,T4..)' end);

  -- c. M4 sent: M3 never returned; T4 returned (once) after it
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 c', 'Zz', 'C', 'adult', 'zz-v147-c@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M4', 'zz-v147-c@example.invalid');
  v := pg_temp.v147_due(st, '2031-07-24') || ' | ' || pg_temp.v147_due(st, '2031-08-02');
  perform pg_temp.v147_sent(st, '2031-07-01', 'T4', 'info@mybjj.com.au');
  v := v || ' | ' || pg_temp.v147_due(st, '2031-08-02');
  out := out || format(E'\n  c M4 sent: M3 due (+23) | T4 due (+32) | after T4 sent = %s -> %s', v,
    case when v = '- | T4@2031-07-01>info@mybjj.com.au | -' then 'pass' else 'FAIL (expected - | T4.. | -)' end);

  -- d. normal member, nothing sent: identical to 146 (M1 at last + 10 + settle)
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 d', 'Zz', 'D', 'adult', 'zz-v147-d@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  v := pg_temp.v147_due(st, '2031-07-12') || ' | ' || pg_temp.v147_due(st, '2031-07-13') || ' | ' || pg_temp.v147_due(st, '2031-07-17');
  out := out || format(E'\n  d nothing sent: +11 | +12 | +16 = %s -> %s', v,
    case when v = '- | M1@2031-07-01>zz-v147-d@example.invalid | M2@2031-07-01>zz-v147-d@example.invalid' then 'pass'
         else 'FAIL (expected - | M1 | M2)' end);

  -- e1. new episode after a class: old episode's M2 does not block the new M1
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 e1', 'Zz', 'E', 'adult', 'zz-v147-e1@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M2', 'zz-v147-e1@example.invalid');
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-20', 'beg');
  v := pg_temp.v147_due(st, '2031-08-01');
  out := out || format(E'\n  e1 new episode after a class: M1 at class+12 = %s -> %s', v,
    case when v = 'M1@2031-07-20>zz-v147-e1@example.invalid' then 'pass' else 'FAIL (expected M1@2031-07-20)' end);
  -- e2. new episode after a resume stamp
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 e2', 'Zz', 'E', 'adult', 'zz-v147-e2@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-06-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-06-01', 'M2', 'zz-v147-e2@example.invalid');
  update public.students set mia_resume_at = (timestamp '2031-07-01 10:00' at time zone syd) where id = st;
  v := pg_temp.v147_due(st, '2031-07-13');
  out := out || format(E'\n  e2 new episode after a resume: M1 at resume+12 = %s -> %s', v,
    case when v = 'M1@2031-07-01>zz-v147-e2@example.invalid' then 'pass' else 'FAIL (expected M1@2031-07-01)' end);

  -- f. a claim in progress ('failed' / 'sending') blocks like 'sent'; a real failure does not
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 f', 'Zz', 'F', 'adult', 'zz-v147-f@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M2', 'zz-v147-f@example.invalid', 'failed', 'sending');
  v := pg_temp.v147_due(st, '2031-07-13');
  update public.email_sends set error = 'resend 500' where period_key = st::text || ':2031-07-01:M2';
  v := v || ' | ' || pg_temp.v147_due(st, '2031-07-13');
  out := out || format(E'\n  f M2 claim in progress | M2 failed for real: M1 due = %s -> %s', v,
    case when v = '- | M1@2031-07-01>zz-v147-f@example.invalid' then 'pass' else 'FAIL (expected - | M1..)' end);

  -- g. the same code is not counted: a second guardian still gets M1 after the first got it
  insert into public.students (full_name, first_name, last_name, prog, active, standing)
    values ('zz v147 g', 'Zz', 'G', 'kids', true, 'ok') returning id into st;
  -- pending invites as 133 defines them: origin is NOT NULL and checked; 'legacy_sync'
  -- needs no created_by (guardianships_created_by_required); an invite_email
  -- identifies the guardian (guardianships_identifies_someone).
  insert into public.guardianships (student_id, invite_email, status, origin) values
    (st, 'zz-v147-g1@example.invalid', 'pending', 'legacy_sync'),
    (st, 'zz-v147-g2@example.invalid', 'pending', 'legacy_sync');
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M1', 'zz-v147-g1@example.invalid');
  v := pg_temp.v147_due(st, '2031-07-13');
  out := out || format(E'\n  g kid, M1 sent to guardian 1: M1 due = %s -> %s', v,
    case when v = 'M1@2031-07-01>zz-v147-g2@example.invalid' then 'pass' else 'FAIL (expected M1 to guardian 2 only)' end);

  -- h. R unaffected: M2 sent... then back in class -> R (needs the episode's M1)
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 h', 'Zz', 'H', 'adult', 'zz-v147-h@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M1', 'zz-v147-h@example.invalid');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M2', 'zz-v147-h@example.invalid');
  insert into public.attendance (student_id, status, class_date, class_type, confirmed_at)
    values (st, 'present', '2031-07-20', 'beg', timestamp '2031-07-20 20:00' at time zone syd);
  v := pg_temp.v147_due(st, '2031-07-21');
  out := out || format(E'\n  h R after M1+M2 sent, back in class = %s -> %s', v,
    case when v = 'R@2031-07-01>zz-v147-h@example.invalid' then 'pass' else 'FAIL (expected R@2031-07-01)' end);

  -- i. T4 sent, M4 failed for real -> M4 returned for retry; M3 still not returned
  insert into public.students (full_name, first_name, last_name, prog, email, active, standing)
    values ('zz v147 i', 'Zz', 'I', 'adult', 'zz-v147-i@example.invalid', true, 'ok') returning id into st;
  insert into public.attendance (student_id, status, class_date, class_type) values (st, 'present', '2031-07-01', 'beg');
  perform pg_temp.v147_sent(st, '2031-07-01', 'T4', 'info@mybjj.com.au');
  perform pg_temp.v147_sent(st, '2031-07-01', 'M4', 'zz-v147-i@example.invalid', 'failed', 'resend 500');
  v := pg_temp.v147_due(st, '2031-08-02') || ' | ' || pg_temp.v147_due(st, '2031-07-24');
  out := out || format(E'\n  i T4 sent, M4 failed: M4 due (+32) | M3 due (+23) = %s -> %s', v,
    case when v = 'M4@2031-07-01>zz-v147-i@example.invalid | -' then 'pass' else 'FAIL (expected M4 retry | -)' end);

  raise exception 'V147 results (rolled back):%', out;
end $$;
