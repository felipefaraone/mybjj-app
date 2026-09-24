-- ============================================================================
-- 131 — staff can invite and remove, without the whitelist opening up
-- ============================================================================
--
-- THE GAP
--
-- whitelist_admin is is_admin(), which is is_unit_owner_any(). An instructor
-- cannot write to the table. But an instructor CAN create a student, change
-- their email and delete them, and every one of those paths writes to the
-- whitelist:
--
--   sendInvite         2 upserts   (student, and the parent of a kid)
--   executeChangeEmail 1 upsert
--   saveEmailEditor    2 upserts   (student and parent)
--   saveEditStu        1 upsert    (second parent)
--   deleteStudent      2 deletes   (student and parent email)
--
-- Every one of them ends in `.then(r => r.error ? console.warn(...))`. So when
-- the write is refused the student is still created, the screen says nothing,
-- and the failure surfaces weeks later as "I cannot log in". That is exactly
-- how 319 people ended up unable to sign in by any path in September: the
-- import wrote students.email and never the whitelist, and it presented as
-- "Send invite is not working for one guy".
--
-- Proved rather than assumed, by impersonating the only ordinary instructor
-- with an account:
--
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<instructor>","role":"authenticated"}';
--   insert into public.whitelist (email, role, unit_id) values (...);
--   -- ERROR: 42501 new row violates row-level security policy
--
-- The delete matters more than the insert. An instructor removing a student
-- leaves their email on the whitelist, and that person can still get in.
--
-- WHY AN RPC AND NOT A LOOSER POLICY
--
-- Relaxing whitelist_admin to `is_admin() OR is_staff()` is one line, and it
-- lets any instructor add any email at all to the list of people who may enter
-- the app. Creating a student and granting access to an arbitrary address are
-- different permissions, and the looser policy fuses them.
--
-- These functions grant access only to an address attached to something the
-- caller is allowed to manage, and they run as definer so the table stays shut.
--
-- DORMANT, NOT HARMLESS
--
-- Nothing is broken today because only owners have created students so far:
-- every recent whitelist row was written by Patricia or Evelin, both owners.
-- It becomes visible the moment an instructor is asked to help enrol people,
-- which is precisely what a student rollout looks like.
--
-- Two students had already slipped through, both created via Add Student in
-- September: one adult and one kid's parent. Both were added by hand, and the
-- count of active students with an email but no whitelist row is now zero.
-- ============================================================================

create or replace function public.whitelist_upsert(
  p_email      text,
  p_role       text,
  p_unit_id    uuid    default null,
  p_student_id uuid    default null
) returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- Staff or owner. Same bar as creating the student in the first place.
  if not (public.is_unit_owner_any() or public.is_staff()) then
    raise exception 'not authorised to invite';
  end if;

  if p_email is null or btrim(p_email) = '' then
    raise exception 'email required';
  end if;

  if p_role not in ('student','parent','instructor') then
    raise exception 'invalid role: %', p_role;
  end if;

  -- Only an owner may grant instructor access. An instructor enrolling members
  -- has no reason to create another instructor, and that is the one role that
  -- carries write access to other people's records.
  if p_role = 'instructor' and not public.is_unit_owner_any() then
    raise exception 'only an owner can invite an instructor';
  end if;

  insert into public.whitelist (email, role, unit_id, student_id, invited_by)
  values (lower(btrim(p_email)), p_role, p_unit_id, p_student_id, v_uid)
  on conflict (email) do update
    set role       = excluded.role,
        unit_id    = coalesce(excluded.unit_id, public.whitelist.unit_id),
        student_id = coalesce(excluded.student_id, public.whitelist.student_id),
        invited_by = excluded.invited_by;
end;
$function$;

create or replace function public.whitelist_remove(p_email text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not (public.is_unit_owner_any() or public.is_staff()) then
    raise exception 'not authorised to remove';
  end if;

  if p_email is null or btrim(p_email) = '' then
    return;   -- nothing to remove; deleting a student with no email is normal
  end if;

  delete from public.whitelist where lower(email) = lower(btrim(p_email));
end;
$function$;

-- The table policy is unchanged: direct writes stay owner-only. These two
-- functions are the only way staff touch it.
