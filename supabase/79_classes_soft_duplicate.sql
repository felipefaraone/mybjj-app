-- 79_classes_soft_duplicate.sql
-- Remove hard UNIQUE (unit_id, day_of_week, time, type) on public.classes.
-- Rationale: Camperdown HQ runs legit simultaneous same-type classes (2 mats).
-- Duplicate protection moves to a soft client-side confirm in the class save
-- flow. NB (1 mat) still gets the confirm as an accident guard.
-- Idempotent: drops only the unique constraint whose columns are exactly
-- (unit_id, day_of_week, time, type); no-op if already removed.
do $$
declare cname text;
begin
  select con.conname into cname
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'classes'
    and con.contype = 'u'
    and (
      select array_agg(att.attname::text order by att.attname::text)
      from unnest(con.conkey) as k(attnum)
      join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k.attnum
    ) = array['day_of_week','time','type','unit_id']::text[]
  limit 1;
  if cname is not null then
    execute format('alter table public.classes drop constraint %I', cname);
    raise notice 'Dropped unique constraint %', cname;
  else
    raise notice 'No matching (unit_id,day_of_week,time,type) unique constraint found';
  end if;
end $$;

-- The hard duplicate protection also existed as a standalone unique INDEX
-- (classes_unit_day_time_type_idx), separate from the constraint the DO
-- block above drops. Drop it too so simultaneous same-type classes are
-- allowed. Idempotent: no-op if the index is already gone.
drop index if exists public.classes_unit_day_time_type_idx;
