-- 122_audit_log.sql
-- 5 September 2026
--
-- PURPOSE
-- Version public.audit_log and the audit_row trigger function, applied directly
-- in the SQL Editor. First audit trail in the database.
--
-- WHY THIS EXISTS
-- The head instructor's belt timeline was overwritten twice, and three of his
-- promotion rows disappeared entirely. Reconstructing what happened took hours
-- of reading ad-hoc _bak_* tables and git log, and the answer was still partly a
-- guess: nothing recorded who changed what, or when. That is the real problem
-- behind "if we cannot make the data credible, John and Patricia will never
-- trust it" — not that rows change, but that nobody can tell afterwards.
--
-- ONE GENERIC FUNCTION, NOT ONE PER TABLE
-- audit_row() reads TG_TABLE_NAME and TG_ARGV, so attaching it elsewhere is a
-- CREATE TRIGGER and nothing else.
--
-- THE COLUMN FILTER IS NOT AN OPTIMISATION, IT IS THE DIFFERENCE BETWEEN
-- USABLE AND USELESS
-- recompute_student_stats UPDATEs public.students on every single attendance
-- mark. Auditing every column would bury the eight fields that matter under
-- thousands of rows of recalculated counters. Passing column names as trigger
-- arguments means students is only audited when belt, degree, journey, the two
-- start dates, a baseline or active actually change. promotions has no filter:
-- every row is worth keeping.
--
-- KNOWN GAP — MANUAL FIXES STAY ANONYMOUS
-- auth.uid() is null under the service role, which is what the SQL Editor uses.
-- So our own repairs record WHAT changed and WHEN, but not by whom. The app is
-- fully covered; the humans typing SQL are not. Worth knowing before trusting
-- actor_user_id to be populated.
--
-- READ ACCESS IS OWNER-ONLY. old_data and new_data are whole-row snapshots and
-- include everything on the row — medical notes, dates of birth, contact
-- details. Anything less restrictive would leak the columns the source tables
-- protect.

create table if not exists public.audit_log (
  id            bigserial primary key,
  table_name    text        not null,
  row_id        uuid        not null,
  op            text        not null check (op in ('INSERT','UPDATE','DELETE')),
  actor_user_id uuid,
  old_data      jsonb,
  new_data      jsonb,
  changed_at    timestamptz not null default now()
);

create index if not exists audit_log_row_idx
  on public.audit_log using btree (table_name, row_id, changed_at desc);
create index if not exists audit_log_time_idx
  on public.audit_log using btree (changed_at desc);

alter table public.audit_log enable row level security;

drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log
for select using (public.is_unit_owner_any());

create or replace function public.audit_row()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_watch text[] := TG_ARGV;   -- optional: only audit when these columns change
  v_col text;
  v_changed boolean := false;
begin
  if TG_OP = 'UPDATE' and array_length(v_watch,1) is not null then
    foreach v_col in array v_watch loop
      if (to_jsonb(OLD) -> v_col) is distinct from (to_jsonb(NEW) -> v_col) then
        v_changed := true;
        exit;
      end if;
    end loop;
    if not v_changed then return NEW; end if;
  end if;

  insert into public.audit_log (table_name, row_id, op, actor_user_id, old_data, new_data)
  values (
    TG_TABLE_NAME,
    coalesce(NEW.id, OLD.id),
    TG_OP,
    auth.uid(),
    case when TG_OP in ('UPDATE','DELETE') then to_jsonb(OLD) else null end,
    case when TG_OP in ('INSERT','UPDATE') then to_jsonb(NEW) else null end
  );
  return coalesce(NEW, OLD);
end $function$;

drop trigger if exists trg_audit_promotions on public.promotions;
create trigger trg_audit_promotions
after insert or update or delete on public.promotions
for each row execute function public.audit_row();

drop trigger if exists trg_audit_students on public.students;
create trigger trg_audit_students
after insert or update or delete on public.students
for each row execute function public.audit_row(
  'belt','degree','journey','bjj_start_date','training_started_at',
  'baseline_total','baseline_grade','active'
);
