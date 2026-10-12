-- 144_email_daily_limit_verify.sql
--
-- V1 is read-only. V2 is one DO block that ENDS WITH RAISE EXCEPTION carrying the
-- results: the "ERROR:  V144 ..." message IS the report; nothing persists.

-- ---------------------------------------------------------------------------
-- V1. The function exists, SECURITY DEFINER, closed to clients.
--     Expected: one row, definer t, anon f, authenticated f, service_role t.
-- ---------------------------------------------------------------------------
select p.proname, p.prosecdef as definer,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute') as service_role
  from pg_proc p
 where p.oid = 'public.email_sent_today(text, timestamptz)'::regprocedure;

-- ---------------------------------------------------------------------------
-- V2. Cases (rolled back). Every case uses its own throwaway address, and
--     "today" is 15 Jul 2031 15:30 Sydney, so real rows never interfere.
--     Expected: every case "pass".
-- ---------------------------------------------------------------------------
do $$
declare
  t   timestamptz := (date '2031-07-15' + time '15:30') at time zone 'Australia/Sydney';
  tod timestamptz := (date '2031-07-15' + time '09:00') at time zone 'Australia/Sydney';
  yst timestamptz := (date '2031-07-14' + time '20:00') at time zone 'Australia/Sydney';
  out text := ''; v boolean;
begin
  -- 1 no rows
  v := public.email_sent_today('zz-v144-none@example.invalid', t);
  out := out || format(E'\n  1 no rows -> %s: %s', v, case when v is false then 'pass' else 'FAIL' end);
  -- 2 a sent MIA row today
  insert into public.email_sends (kind, period_key, recipient_email, status, sent_at)
    values ('mia', 'zz-v144:2031-07-01:M1', 'zz-v144-mia@example.invalid', 'sent', tod);
  v := public.email_sent_today('zz-v144-mia@example.invalid', t);
  out := out || format(E'\n  2 sent MIA row today -> %s: %s', v, case when v then 'pass' else 'FAIL' end);
  -- 3 a sent row yesterday (Sydney)
  insert into public.email_sends (kind, period_key, recipient_email, status, sent_at)
    values ('mia', 'zz-v144:2031-07-01:M2', 'zz-v144-yday@example.invalid', 'sent', yst);
  v := public.email_sent_today('zz-v144-yday@example.invalid', t);
  out := out || format(E'\n  3 sent row yesterday -> %s: %s', v, case when v is false then 'pass' else 'FAIL' end);
  -- 4 only trial '1' and '2' today (exempt)
  insert into public.email_sends (kind, period_key, recipient_email, status, sent_at) values
    ('trial', 'zz-v144-sess:1', 'zz-v144-conf@example.invalid', 'sent', tod),
    ('trial', 'zz-v144-sess:2', 'zz-v144-conf@example.invalid', 'sent', tod);
  v := public.email_sent_today('zz-v144-conf@example.invalid', t);
  out := out || format(E'\n  4 only trial 1 / 2 today -> %s: %s', v, case when v is false then 'pass' else 'FAIL' end);
  -- 5 a trial '3A' today
  insert into public.email_sends (kind, period_key, recipient_email, status, sent_at)
    values ('trial', 'zz-v144-sess:3A', 'zz-v144-t3a@example.invalid', 'sent', tod);
  v := public.email_sent_today('zz-v144-t3a@example.invalid', t);
  out := out || format(E'\n  5 trial 3A today -> %s: %s', v, case when v then 'pass' else 'FAIL' end);
  -- 6 only an info@ row (team note)
  insert into public.email_sends (kind, period_key, recipient_email, status, sent_at)
    values ('mia', 'zz-v144:2031-07-01:T4', 'info@mybjj.com.au', 'sent', tod);
  v := (select public.email_sent_today('info@mybjj.com.au', t));
  out := out || format(E'\n  6 only an info@ row -> %s: %s', v, case when v is false then 'pass' else 'FAIL' end);
  -- 7 mixed case and spaces still match
  v := public.email_sent_today('  ZZ-V144-MIA@Example.INVALID ', t);
  out := out || format(E'\n  7 mixed case and spaces -> %s: %s', v, case when v then 'pass' else 'FAIL' end);
  -- 8 a claim in progress (failed / sending, no sent_at: created_at today)
  insert into public.email_sends (kind, period_key, recipient_email, status, error, created_at)
    values ('mia', 'zz-v144:2031-07-01:M3', 'zz-v144-claim@example.invalid', 'failed', 'sending', tod);
  v := public.email_sent_today('zz-v144-claim@example.invalid', t);
  out := out || format(E'\n  8 claimed, being sent -> %s: %s', v, case when v then 'pass' else 'FAIL' end);
  -- 9 a failed send (did not go out) and a skipped row
  insert into public.email_sends (kind, period_key, recipient_email, status, error, created_at) values
    ('mia', 'zz-v144:2031-07-01:M4', 'zz-v144-fail@example.invalid', 'failed', 'HTTP 500: stub', tod),
    ('trial', 'zz-v144-sess:4A', 'zz-v144-fail@example.invalid', 'skipped', 'superseded by 5A', tod);
  v := public.email_sent_today('zz-v144-fail@example.invalid', t);
  out := out || format(E'\n  9 failed send / skipped only -> %s: %s', v, case when v is false then 'pass' else 'FAIL' end);

  raise exception 'V144 results (rolled back):%', out;
end $$;
