-- =============================================================================
-- Migration 43: attendance.class_id FK → ON DELETE RESTRICT
-- Run AFTER 42_phase8_notifications.sql. Idempotent (DROP IF EXISTS + ADD).
--
-- Already applied directly in the Supabase SQL Editor; this file exists
-- for reproducibility and git history.
--
-- Before: attendance.class_id had ON DELETE SET NULL — a hard delete of
-- a public.classes row would silently orphan every attendance row that
-- pointed at it, losing the link between historical check-ins and the
-- class they belonged to.
--
-- After: RESTRICT. The DB refuses to delete a class row if any
-- attendance row references it (raises foreign_key_violation, SQLSTATE
-- 23503). The frontend's confDel catches that code and surfaces the
-- friendly "This class has attendance records and cannot be deleted.
-- Edit it instead." toast — see index.html confDel().
--
-- The `active` column on public.classes is left in place for now (it's
-- the safety net the hydrate query still filters on, and a future
-- batch may decide to drop it — out of scope here).
-- =============================================================================

alter table public.attendance
  drop constraint if exists attendance_class_id_fkey;

alter table public.attendance
  add constraint attendance_class_id_fkey
  foreign key (class_id) references public.classes(id) on delete restrict;

-- ---------------------------------------------------------------------------
-- Verify the rule landed
-- ---------------------------------------------------------------------------
do $$
declare
  rule text;
begin
  select delete_rule into rule
    from information_schema.referential_constraints
   where constraint_name = 'attendance_class_id_fkey';

  if rule <> 'RESTRICT' then
    raise exception 'Migration 43: expected RESTRICT, got %', rule;
  end if;

  raise notice 'Migration 43: attendance_class_id_fkey delete_rule = RESTRICT';
end $$;
