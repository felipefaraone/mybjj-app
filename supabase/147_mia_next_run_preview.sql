-- 147_mia_next_run_preview.sql
--
-- READ-ONLY. What the NEXT mia-emails run would send if it ran right now: one
-- row per email row public.mia_email_candidates(now()) returns (147's rules,
-- including "never step back"). Run it as the owner in the SQL editor before
-- resuming the cron.
--
-- Note: the Edge Function then groups rows by (recipient, code, kids/adults) into
-- one email, applies the one-email-per-address-per-Sydney-day limit (144), the
-- daily cap and the 60-per-run limit, so the run may send FEWER emails than rows
-- here; it never sends a row that is not here.

with c as (
  select * from public.mia_email_candidates(now())
)
select s.full_name                                         as student,
       s.prog,
       c.unit_name                                         as unit,
       c.code,
       c.recipient,
       c.last_class_date                                   as last_class,
       split_part(c.period_key, ':', 2)::date               as anchor_date,
       ((now() at time zone 'Australia/Sydney')::date
         - split_part(c.period_key, ':', 2)::date)         as days_since_anchor,
       s.mia_resume_at,
       s.converted_at,
       (select string_agg(split_part(es.period_key, ':', 3) || ' ' || es.status
                          || coalesce(' (' || to_char(es.sent_at at time zone 'Australia/Sydney', 'YYYY-MM-DD HH24:MI') || ')', '')
                          || ' -> ' || es.recipient_email::text,
                          '; ' order by es.sent_at nulls last, es.period_key)
          from public.email_sends es
         where es.kind = 'mia'
           and es.period_key like c.student_id::text || ':' || split_part(c.period_key, ':', 2) || ':%')
                                                           as already_this_episode,
       c.due_at at time zone 'Australia/Sydney'            as due_sydney,
       c.attempt_status
  from c
  join public.students s on s.id = c.student_id
 order by c.unit_name nulls last, c.code, s.full_name, c.recipient;
