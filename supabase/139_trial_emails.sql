-- ============================================================================
-- 139 — Trial follow-up emails: who marked a no-show, the 'trial' email kind,
--       and the list of trial emails due now
-- ============================================================================
--
-- WHY
-- The head instructor wrote a trial email sequence (adult and kids streams):
--   1  immediately         (sent by trial-booking at booking time, not here)
--   2  24 hours before     (the class's clock time, one day before)
--   3A/4A/5A/6A            after an ATTENDED trial: day +1, +2, +5, +9 at 09:00
--   3B/4B/5B               after a STAFF-MARKED no-show: day +1, +3, +7 at 09:00
-- All times Sydney, counted from the session's class date. An email more than
-- 2 days past its time is never sent late. Nothing here sends or schedules: the
-- trial-emails Edge Function reads trial_email_candidates() and logs every
-- attempt in email_sends (kind 'trial').
--
-- 1. trial_bookings.no_show_by / no_show_marked_at
--    Who marked the no-show, and when. The app's "No show" button writes both;
--    "Undo no-show" clears both. The automatic overnight process (not in this
--    repo; it sets trial_status='no_show' + lapsed_at) does not know these
--    columns, so it leaves them NULL — and the no-show stream starts ONLY when
--    no_show_by is set. A trial nobody marked gets no follow-up.
--
-- 2. email_sends.kind / email_optouts.kind gain 'trial'.
--    period_key for a trial email = '<session key>:<code>', e.g. '…:3A', where
--    the session key is the trial_sessions id, or the trial_bookings id for a
--    lead that has only the original (legacy) class.
--    IDEMPOTENCY: 137's unique key is (kind, period_key, student_id,
--    recipient_email). Trial rows have no student (student_id NULL), and NULLs
--    never collide in a unique constraint, so that key alone would NOT stop a
--    second row. email_sends_trial_once adds (period_key, recipient_email) unique
--    for kind 'trial' only. (Not for every kind: a recap row whose student was
--    deleted also ends up with student_id NULL, and those must stay legal.)
--
-- 3. trial_email_candidates(p_now): every trial email due at p_now, with every
--    stop rule applied:
--      - converted lead (trial_status 'converted' or converted_at set): nothing
--      - only the lead's CURRENT session streams: the latest by class date and
--        time. A newer booking for the same lead stops the old stream and starts
--        a new one (its own period keys).
--      - email 2: the lead is booked/attended, the class is still ahead, and the
--        session was booked more than 24h before it. For an added session with
--        no recorded creation time this is unknowable, so email 2 is skipped
--        rather than sent at the wrong moment (see the report).
--      - A branch: trial_status 'attended' and attended_at on or after the
--        current session's class date.
--      - B branch: trial_status 'no_show', no_show_by set, and no_show_marked_at
--        on or after the current session's class date (a mark left over from an
--        older session never starts a stream for a newer one).
--      - status no longer matching its branch (undo no-show, lapse, …): nothing
--      - the address opted out (kind 'all' or 'trial'): nothing
--      - already sent or skipped for that period key + address: nothing
--      - bookings with no class ("none of these times work"): no session, so
--        nothing here (email 1 only, from trial-booking)
--    Closed to clients; service_role only. Text columns cast at the source.
--
-- Rollback: 139_trial_emails_rollback.sql. Checks: 139_trial_emails_verify.sql.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Preflight: the two kind CHECKs hold exactly 137's values (or 139's, on a
--    re-run). Anything else: abort rather than drop an unknown value.
-- ---------------------------------------------------------------------------
do $$
declare v_def text; v_vals text[]; r record;
begin
  for r in select * from (values
    ('public.email_sends',   'email_sends_kind_check',   array['mia','monthly_recap']),
    ('public.email_optouts', 'email_optouts_kind_check', array['all','mia','monthly_recap'])
  ) as t(tbl, conname, expected) loop
    select pg_get_constraintdef(c.oid) into v_def
      from pg_constraint c where c.conrelid = r.tbl::regclass and c.conname = r.conname;
    if v_def is null then raise exception '139 preflight: % not found on %', r.conname, r.tbl; end if;
    select array_agg(m[1] order by m[1]) into v_vals from regexp_matches(v_def, '''([^'']+)''', 'g') m;
    if not (v_vals = r.expected
            or v_vals = (select array_agg(x order by x) from unnest(r.expected || array['trial']) x)) then
      raise exception '139 preflight: % is % (expected %)', r.conname, v_vals, r.expected;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Who marked the no-show
-- ---------------------------------------------------------------------------
alter table public.trial_bookings
  add column if not exists no_show_by        uuid references public.users(id) on delete set null,
  add column if not exists no_show_marked_at timestamptz;
comment on column public.trial_bookings.no_show_by is
  'The staff user who marked this trial a no-show (the app''s No show button). NULL when the automatic overnight process set no_show — the no-show emails start only when this is set (migration 139). Undo no-show clears it.';
comment on column public.trial_bookings.no_show_marked_at is
  'When no_show_by marked the no-show (migration 139).';

-- ---------------------------------------------------------------------------
-- 2. The 'trial' kind, and trial idempotency
-- ---------------------------------------------------------------------------
alter table public.email_sends drop constraint if exists email_sends_kind_check;
alter table public.email_sends add constraint email_sends_kind_check
  check (kind in ('monthly_recap','mia','trial'));
alter table public.email_optouts drop constraint if exists email_optouts_kind_check;
alter table public.email_optouts add constraint email_optouts_kind_check
  check (kind in ('all','monthly_recap','mia','trial'));
create unique index if not exists email_sends_trial_once
  on public.email_sends (period_key, recipient_email)
  where kind = 'trial';

-- ---------------------------------------------------------------------------
-- 3. trial_email_candidates
-- ---------------------------------------------------------------------------
create or replace function public.trial_email_candidates(p_now timestamptz)
returns table (
  booking_id       uuid,
  session_key      text,
  session_id       uuid,
  stream           text,          -- 'adult' | 'kids'
  code             text,          -- '2','3A','4A','5A','6A','3B','4B','5B'
  due_at           timestamptz,
  period_key       text,          -- '<session_key>:<code>'
  recipient        text,          -- lowercased, trimmed
  first_name       text,          -- the booker (the parent, for kids)
  child_first_name text,          -- first word of kid_name (kids only)
  unit_name        text,
  unit_legacy_id   text,          -- for trial.html?unit=
  unit_address     text,
  unit_city        text,
  unit_phone       text,
  class_type       text,
  class_audience   text,
  class_date       date,
  class_time       text,          -- 'HH:MM'
  attempt_status   text           -- 'failed' when a previous attempt failed, else NULL
)
language sql
stable
security definer
set search_path = public
as $$
  with sess as (
    -- Every session of every lead: trial_sessions rows, else the legacy trio on
    -- the booking itself. created_at is read through to_jsonb so the function
    -- works whether or not trial_sessions has that column (not in this repo).
    select ts.trial_booking_id as booking_id, ts.id as session_id, ts.id::text as session_key,
           ts.class_id, ts.class_date, left(ts.class_time::text, 5) as class_time,
           (to_jsonb(ts) ->> 'created_at')::timestamptz as created_at
      from public.trial_sessions ts
     where ts.class_date is not null
    union all
    select tb.id, null::uuid, tb.id::text, tb.class_id, tb.class_date, left(tb.class_time::text, 5), tb.booked_at
      from public.trial_bookings tb
     where tb.class_date is not null
       and not exists (select 1 from public.trial_sessions x where x.trial_booking_id = tb.id)
  ),
  cur as (
    -- The lead's CURRENT session: the latest by class date and time.
    select distinct on (s.booking_id) s.*
      from sess s
     order by s.booking_id, s.class_date desc, s.class_time desc nulls last, s.session_key desc
  ),
  lead as (
    select c.booking_id, c.session_id, c.session_key, c.class_id, c.class_date, c.class_time,
           tb.trial_status::text as trial_status, tb.attended_at, tb.no_show_by, tb.no_show_marked_at,
           coalesce(tb.is_kid, false) as is_kid, tb.first_name::text as first_name, tb.kid_name::text as kid_name,
           nullif(lower(btrim(tb.email::text)), '') as recipient, tb.unit_id,
           ((c.class_date + coalesce(c.class_time, '00:00')::time) at time zone 'Australia/Sydney') as starts_at,
           -- when THIS session was booked: its own created_at, else the booking's
           -- booked_at when the session is the original class, else unknown.
           coalesce(c.created_at,
                    case when c.session_id is null
                           or (c.class_id is not distinct from tb.class_id and c.class_date = tb.class_date)
                         then tb.booked_at end) as session_booked_at
      from cur c
      join public.trial_bookings tb on tb.id = c.booking_id
     where tb.converted_at is null
       and tb.trial_status is distinct from 'converted'
  ),
  codes(code, branch, day_offset) as (
    values ('2','R',-1), ('3A','A',1), ('4A','A',2), ('5A','A',5), ('6A','A',9),
           ('3B','B',1), ('4B','B',3), ('5B','B',7)
  ),
  due as (
    select l.*, k.code,
           case when k.branch = 'R' then l.starts_at - interval '1 day'
                else ((l.class_date + k.day_offset) + time '09:00') at time zone 'Australia/Sydney'
           end as due_at
      from lead l
     cross join codes k
     where case k.branch
             when 'R' then l.trial_status in ('booked','attended')
                       and p_now < l.starts_at
                       and l.session_booked_at is not null
                       and l.session_booked_at < l.starts_at - interval '24 hours'
             when 'A' then l.trial_status = 'attended'
                       and l.attended_at is not null
                       and (l.attended_at at time zone 'Australia/Sydney')::date >= l.class_date
             when 'B' then l.trial_status = 'no_show'
                       and l.no_show_by is not null
                       and l.no_show_marked_at is not null
                       and (l.no_show_marked_at at time zone 'Australia/Sydney')::date >= l.class_date
             else false
           end
  )
  select d.booking_id,
         d.session_key::text,
         d.session_id,
         (case when d.is_kid then 'kids' else 'adult' end)::text,
         d.code::text,
         d.due_at,
         (d.session_key || ':' || d.code)::text,
         d.recipient::text,
         nullif(btrim(d.first_name), '')::text,
         (case when d.is_kid then nullif(split_part(btrim(coalesce(d.kid_name, '')), ' ', 1), '') end)::text,
         u.name::text,
         lower(u.legacy_id::text)::text,
         nullif(btrim(u.address::text), '')::text,
         nullif(btrim(u.city::text), '')::text,
         nullif(btrim(u.phone::text), '')::text,
         cl.type::text,
         cl.audience::text,
         d.class_date,
         d.class_time::text,
         (select es.status::text from public.email_sends es
           where es.kind = 'trial' and es.period_key = d.session_key || ':' || d.code
             and lower(es.recipient_email::text) = d.recipient and es.status = 'failed' limit 1)
    from due d
    join public.units u    on u.id = d.unit_id
    left join public.classes cl on cl.id = d.class_id
   where d.due_at <= p_now
     and d.due_at >= p_now - interval '2 days'          -- never more than 2 days late
     and d.recipient is not null
     and not exists (select 1 from public.email_optouts o
                      where lower(o.email::text) = d.recipient and o.kind in ('all','trial'))
     and not exists (select 1 from public.email_sends es
                      where es.kind = 'trial' and es.period_key = d.session_key || ':' || d.code
                        and lower(es.recipient_email::text) = d.recipient
                        and es.status in ('sent','skipped'))
   order by d.due_at, d.booking_id, d.code
$$;

revoke all on function public.trial_email_candidates(timestamptz) from public, anon, authenticated;
grant execute on function public.trial_email_candidates(timestamptz) to service_role;

commit;
