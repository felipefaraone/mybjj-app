-- 171_preview.sql — READ ONLY. Run BEFORE 171, with psql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/171_preview.sql
-- A read only transaction ending in ROLLBACK: it cannot change anything.
-- Prints, in order:
--   1. the columns 171 uses, from information_schema (none missing = 11 rows);
--   2. every trigger on public.attendance (171 adds trg_attendance_open_mat_value);
--   3. each present open-mat row the backfill will change (student, date, time,
--      current class_value, recurring or one-off);
--   4. the count per student;
--   5. the totals.
-- The open-mat test is 171's _is_open_mat, inlined (171 is not applied yet).

begin;
set transaction read only;

-- 1. columns
select i.table_name, i.column_name, i.data_type, i.is_nullable
  from information_schema.columns i
 where i.table_schema = 'public'
   and (i.table_name, i.column_name) in (
         ('attendance', 'id'), ('attendance', 'student_id'), ('attendance', 'class_id'),
         ('attendance', 'class_legacy_id'), ('attendance', 'class_date'), ('attendance', 'status'),
         ('attendance', 'class_value'), ('classes', 'id'), ('classes', 'level'),
         ('class_exceptions', 'id'), ('class_exceptions', 'oneoff_level'))
 order by i.table_name, i.column_name;

-- 2. triggers on attendance (BEFORE triggers fire in name order)
select t.tgname as trigger,
       case when t.tgtype & 2 = 2 then 'BEFORE' else 'AFTER' end as timing,
       concat_ws(' OR ', case when t.tgtype & 4 = 4 then 'INSERT' end, case when t.tgtype & 16 = 16 then 'UPDATE' end,
                 case when t.tgtype & 8 = 8 then 'DELETE' end) as events,
       t.tgfoid::regproc as function,
       case t.tgenabled when 'D' then 'disabled' else 'enabled' end as state
  from pg_trigger t
 where t.tgrelid = 'public.attendance'::regclass and not t.tgisinternal
 order by timing desc, t.tgname;

-- 3-5 share one row set (the same text each time: a read only transaction
-- cannot create a view)
-- 3. the rows that will change
with om171 as (
  select a."id", a."student_id", a."class_date", a."class_time", a."class_value",
         case when a."class_id" is not null then 'recurring' else 'one-off' end as kind,
         coalesce(a."class_id"::text, a."class_legacy_id") as class_ref
    from public.attendance a
   where a."status" = 'present' and a."class_value" is distinct from 0.25
     and (exists (select 1 from public.classes c where c."id" = a."class_id" and c."level" = 'Open Mat')
          or (strpos(coalesce(a."class_legacy_id", ''), '_oneoff_') > 0
              and exists (select 1 from public.class_exceptions e
                           where e."id"::text = substr(a."class_legacy_id", strpos(a."class_legacy_id", '_oneoff_') + length('_oneoff_'))
                             and e."oneoff_level" = 'Open Mat'))))
select s."full_name" as student, o.class_date, o.class_time, o.class_value as current_value, o.kind, o.class_ref
  from om171 o join public.students s on s."id" = o.student_id
 order by o.class_date, o.class_time, s."full_name";

-- 4. per student
with om171 as (
  select a."id", a."student_id", a."class_date", a."class_time", a."class_value",
         case when a."class_id" is not null then 'recurring' else 'one-off' end as kind,
         coalesce(a."class_id"::text, a."class_legacy_id") as class_ref
    from public.attendance a
   where a."status" = 'present' and a."class_value" is distinct from 0.25
     and (exists (select 1 from public.classes c where c."id" = a."class_id" and c."level" = 'Open Mat')
          or (strpos(coalesce(a."class_legacy_id", ''), '_oneoff_') > 0
              and exists (select 1 from public.class_exceptions e
                           where e."id"::text = substr(a."class_legacy_id", strpos(a."class_legacy_id", '_oneoff_') + length('_oneoff_'))
                             and e."oneoff_level" = 'Open Mat'))))
select s."full_name" as student, count(*) as rows_to_change, sum(o.class_value) as current_sum,
       0.25 * count(*) as sum_after
  from om171 o join public.students s on s."id" = o.student_id
 group by s."id", s."full_name"
 order by count(*) desc, s."full_name";

-- 5. totals
with om171 as (
  select a."id", a."student_id", a."class_date", a."class_time", a."class_value",
         case when a."class_id" is not null then 'recurring' else 'one-off' end as kind,
         coalesce(a."class_id"::text, a."class_legacy_id") as class_ref
    from public.attendance a
   where a."status" = 'present' and a."class_value" is distinct from 0.25
     and (exists (select 1 from public.classes c where c."id" = a."class_id" and c."level" = 'Open Mat')
          or (strpos(coalesce(a."class_legacy_id", ''), '_oneoff_') > 0
              and exists (select 1 from public.class_exceptions e
                           where e."id"::text = substr(a."class_legacy_id", strpos(a."class_legacy_id", '_oneoff_') + length('_oneoff_'))
                             and e."oneoff_level" = 'Open Mat'))))
select count(*) as rows_to_change, count(distinct o.student_id) as students,
       count(*) filter (where o.kind = 'recurring') as recurring, count(*) filter (where o.kind = 'one-off') as one_off
  from om171 o;

rollback;
