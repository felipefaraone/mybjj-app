-- =============================================================================
-- Migration 34: Staff name hygiene + full_name sync trigger
-- Run AFTER 33_phase8_drop_nicknames.sql. Idempotent.
--
-- 1. Soft delete "Prof. Teste" test account
-- 2. Set explicit clean names for known staff (first name + last name only)
-- 3. Defensive cleanup of any remaining "Prof." prefix
-- 4. Trigger that syncs users.full_name when staff/students.full_name changes
-- 5. Back-fill users.full_name from linked staff/students
-- =============================================================================

update public.staff
   set active = false
 where legacy_id = 'test_instructor_s';

update public.staff
   set full_name = 'Mario Yokoyama',
       initials  = 'MY'
 where legacy_id = 'mario_s';

update public.staff
   set full_name = 'Felipe Silva',
       initials  = 'FS'
 where legacy_id = 'felipe_s';

update public.staff
   set full_name = regexp_replace(full_name, '^(Prof\.?|Professor)\s+', '', 'i')
 where active = true
   and (full_name ilike 'Prof.%' or full_name ilike 'Prof %' or full_name ilike 'Professor %');

-- ---------------------------------------------------------------------------
-- Full-name sync triggers — keep users.full_name in lockstep with the
-- linked staff/students row whenever the source name changes.
-- ---------------------------------------------------------------------------
create or replace function public.sync_user_full_name_from_staff()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is not null and new.full_name is distinct from old.full_name then
    update public.users
       set full_name = new.full_name
     where id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_sync_user_full_name_from_staff on public.staff;
create trigger trg_sync_user_full_name_from_staff
after update of full_name on public.staff
for each row
execute function public.sync_user_full_name_from_staff();

create or replace function public.sync_user_full_name_from_student()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.full_name is distinct from old.full_name then
    if new.user_id is not null then
      update public.users
         set full_name = new.full_name
       where id = new.user_id;
    end if;
    -- Do NOT sync to parent_user_id — parent's display name is independent
    -- of the kid's name and managed separately.
  end if;
  return new;
end $$;

drop trigger if exists trg_sync_user_full_name_from_student on public.students;
create trigger trg_sync_user_full_name_from_student
after update of full_name on public.students
for each row
execute function public.sync_user_full_name_from_student();

-- ---------------------------------------------------------------------------
-- Back-fill users.full_name from the linked staff / student row so that
-- post-trigger writes start from a consistent baseline.
-- ---------------------------------------------------------------------------
update public.users u
   set full_name = s.full_name
  from public.staff s
 where s.user_id = u.id
   and s.active = true
   and (u.full_name is null or u.full_name is distinct from s.full_name);

update public.users u
   set full_name = s.full_name
  from public.students s
 where s.user_id = u.id
   and s.active = true
   and (u.full_name is null or u.full_name is distinct from s.full_name);

do $$
declare
  v_prof_remaining int;
  v_mario_name     text;
  v_felipe_name    text;
begin
  select count(*) into v_prof_remaining
    from public.staff
   where active = true
     and (full_name ilike 'Prof.%' or full_name ilike 'Prof %' or full_name ilike 'Professor %');

  select full_name into v_mario_name  from public.staff where legacy_id='mario_s';
  select full_name into v_felipe_name from public.staff where legacy_id='felipe_s';

  raise notice 'Migration 34: prof_remaining = %, mario = %, felipe = %',
    v_prof_remaining, v_mario_name, v_felipe_name;
end $$;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select legacy_id, full_name, initials, active from public.staff
--   where legacy_id in ('mario_s','felipe_s','test_instructor_s');
-- select count(*) from public.staff
--   where active = true and (full_name ilike 'Prof.%' or full_name ilike 'Prof %');
-- -- Expect 0 rows.
-- select tgname from pg_trigger
--   where tgname in ('trg_sync_user_full_name_from_staff','trg_sync_user_full_name_from_student');
