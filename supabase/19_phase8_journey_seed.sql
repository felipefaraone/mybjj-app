-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — journey seed + unit_id fallback for peers
-- Run AFTER 18_phase8_fix_claim_approval.sql. Safe to re-run.
--
-- Fixes two bugs visible to a freshly-invited student on first sign-in:
--
--   Bug 1. Empty journey looks broken. When claim_profile links the
--          authenticated user to a public.students row (via email match) and
--          that row's journey is null or [], the timeline view has nothing
--          to render. We now seed a single "Joined myBJJ app" milestone
--          using the row's current belt and the current month.
--          (Phase-8 follow-up — original label "Started training" was
--          misleading because most pilot students had been training for
--          years before the app existed.)
--
--   Bug 2. Members tab empty for the student. The students_select RLS
--          policy (02_rls.sql) already permits a student to read peer
--          rows in the same unit, but the comparison is
--          `unit_id = public.current_unit()`, and current_unit() reads
--          users.unit_id which is NULL for any user who pre-existed the
--          whitelist (they self-signed-up before being invited). We
--          extend current_unit() to fall back to the linked students or
--          staff row's unit_id, and one-shot back-fill users.unit_id from
--          those same linked rows.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. current_unit() — fall back to linked student/staff row when the
--    users.unit_id column hasn't been populated yet. Other RLS helpers
--    (is_admin / is_staff / current_role) keep reading from public.users.
-- ---------------------------------------------------------------------------
create or replace function public.current_unit()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select unit_id from public.users    where id      = auth.uid()),
    (select unit_id from public.students where user_id = auth.uid() limit 1),
    (select unit_id from public.staff    where user_id = auth.uid() limit 1),
    (select unit_id from public.students where parent_user_id = auth.uid() limit 1)
  )
$$;

-- ---------------------------------------------------------------------------
-- 2. seed_student_journey_if_empty — helper used by claim_profile to give a
--    freshly-linked student row a starting milestone. Idempotent on the
--    journey content (only writes when journey is null or empty).
-- ---------------------------------------------------------------------------
create or replace function public.seed_student_journey_if_empty(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.students;
  v_month text;
begin
  select * into v_row from public.students where id = p_student_id;
  if not found then return; end if;
  if v_row.journey is not null and jsonb_array_length(v_row.journey) > 0 then
    return;
  end if;
  v_month := to_char(now() at time zone 'utc', 'Mon YYYY');
  update public.students
     set journey = jsonb_build_array(
       jsonb_build_object(
         'label',   'Joined myBJJ app',
         'date',    v_month,
         'classes', 0,
         'done',    true,
         'current', true,
         'belt',    coalesce(v_row.belt, 'white')
       )
     )
   where id = p_student_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. claim_profile — drop and recreate. Same approval logic as migration 18,
--    plus a call to seed_student_journey_if_empty for every students row
--    the function links (self, parent-of-child both paths).
-- ---------------------------------------------------------------------------
create or replace function public.claim_profile()
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := auth.email();
  v_name  text;
  v_existing public.users;
  v_wl    public.whitelist;
  v_stu   uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_existing from public.users where id = v_uid;

  select * into v_wl
    from public.whitelist
   where lower(email) = lower(v_email)
   limit 1;

  if v_existing.id is not null then
    if v_wl.email is not null and v_existing.status = 'pending' then
      update public.users
         set status  = 'approved',
             role    = coalesce(v_wl.role,    v_existing.role),
             unit_id = coalesce(v_wl.unit_id, v_existing.unit_id)
       where id = v_uid
       returning * into v_existing;
    end if;

    -- Auto-link staff / students-self / students-parent. Capture the linked
    -- student id so we can seed their journey if empty.
    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email)
    returning id into v_stu;
    if v_stu is not null then perform public.seed_student_journey_if_empty(v_stu); end if;

    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and lower(parent_email) = lower(v_email);

    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    -- Backfill users.unit_id from the linked rows if it's still NULL — this
    -- is what unblocks the Members tab for users who pre-existed the
    -- whitelist.
    if v_existing.unit_id is null then
      update public.users u
         set unit_id = sub.unit_id
        from (
          select coalesce(
            (select unit_id from public.students where user_id = v_uid limit 1),
            (select unit_id from public.staff    where user_id = v_uid limit 1),
            (select unit_id from public.students where parent_user_id = v_uid limit 1)
          ) as unit_id
        ) sub
       where u.id = v_uid
         and sub.unit_id is not null
       returning u.* into v_existing;
    end if;

    return v_existing;
  end if;

  v_name := coalesce(
    (auth.jwt() -> 'user_metadata' ->> 'full_name'),
    (auth.jwt() -> 'user_metadata' ->> 'name'),
    null
  );

  if v_wl.email is not null then
    insert into public.users (id, email, role, unit_id, status, full_name)
    values (v_uid, v_email, v_wl.role, v_wl.unit_id, 'approved', v_name)
    returning * into v_existing;

    if v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email)
    returning id into v_stu;
    if v_stu is not null then perform public.seed_student_journey_if_empty(v_stu); end if;

    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and lower(parent_email) = lower(v_email);
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;
  end if;

  return v_existing;
end;
$$;

grant execute on function public.claim_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Back-fill: any existing students.user_id linkage whose journey is empty
--    gets the same starting milestone retroactively, so pilot students who
--    already signed in don't keep looking broken.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in select id from public.students
            where user_id is not null
              and (journey is null or jsonb_array_length(journey) = 0)
  loop
    perform public.seed_student_journey_if_empty(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Back-fill: populate users.unit_id from linked student/staff rows for
--    anyone still missing it.
-- ---------------------------------------------------------------------------
update public.users u
   set unit_id = sub.unit_id
  from (
    select u2.id as user_id,
           coalesce(
             (select s.unit_id  from public.students s where s.user_id        = u2.id limit 1),
             (select st.unit_id from public.staff    st where st.user_id      = u2.id limit 1),
             (select s.unit_id  from public.students s where s.parent_user_id = u2.id limit 1)
           ) as unit_id
      from public.users u2
     where u2.unit_id is null
  ) sub
 where u.id = sub.user_id
   and sub.unit_id is not null;

-- ---------------------------------------------------------------------------
-- Verification (uncomment in SQL Editor)
-- ---------------------------------------------------------------------------
-- select id, full_name, jsonb_array_length(journey) as len from public.students;
-- select id, email, role, status, unit_id from public.users where unit_id is null;
