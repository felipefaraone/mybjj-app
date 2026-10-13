-- 146_mia_resume_clock_backfill_preview.sql
--
-- READ-ONLY. Who may have been emailed because a hold / inactive period was
-- counted as absence before 146: members who are active and not on hold now,
-- got an M-code MIA email (M1-M4) in the last 72 hours, and whose last present
-- class was more than 10 days before that send. The owner reviews this list and
-- decides who to stamp (146_mia_resume_clock_backfill_apply.sql). Nothing here
-- writes.
--
-- Columns: one row per member; codes sent in the window with their send times
-- (Sydney), the last present class, and the current mia_resume_at (if 146's
-- trigger already stamped them, e.g. they came off hold after 146 was applied).

with sent as (
  select es.student_id,
         split_part(es.period_key, ':', 3) as code,
         es.sent_at,
         lower(es.recipient_email::text) as recipient
    from public.email_sends es
   where es.kind = 'mia'
     and es.status = 'sent'
     and es.sent_at >= now() - interval '72 hours'
     and split_part(es.period_key, ':', 3) in ('M1', 'M2', 'M3', 'M4')
),
last_class as (
  select a.student_id, max(a.class_date) as last_class
    from public.attendance a
   where a.status = 'present' and a.class_date is not null
   group by a.student_id
)
select s.id,
       s.full_name,
       s.prog,
       u.name as unit,
       lc.last_class,
       string_agg(x.code || ' ' || to_char(x.sent_at at time zone 'Australia/Sydney', 'YYYY-MM-DD HH24:MI')
                  || ' -> ' || x.recipient, '; ' order by x.sent_at, x.code, x.recipient) as sent_in_last_72h,
       min(x.sent_at at time zone 'Australia/Sydney') as first_send_sydney,
       s.mia_resume_at
  from sent x
  join public.students s on s.id = x.student_id
  left join last_class lc on lc.student_id = s.id
  left join public.units u on u.id = s.unit_id
 where s.active is true
   and s.standing is distinct from 'on_hold'
   and (lc.last_class is null or lc.last_class < (x.sent_at at time zone 'Australia/Sydney')::date - 10)
 group by s.id, s.full_name, s.prog, u.name, lc.last_class, s.mia_resume_at
 order by u.name nulls last, s.full_name;
