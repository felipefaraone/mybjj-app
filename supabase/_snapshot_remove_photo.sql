-- Snapshot of remove_photo(p_student_id uuid default null): one function serves both app calls. Created in the SQL Editor, never in a migration.
-- Captured from production on 20 Oct 2026. Reference only: do not re-run blindly.

CREATE OR REPLACE FUNCTION public.remove_photo(p_student_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_target_user uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  if p_student_id is null then
    -- self: clear own photo across subject tables + users
    update public.students set photo_url = null where user_id = v_uid;
    update public.staff    set photo_url = null where user_id = v_uid;
    update public.users    set photo_url = null where id = v_uid;
    delete from public.photo_approvals where user_id = v_uid and status = 'pending';
  else
    -- staff removing a student's photo (owner or instructor)
    if not (public.is_unit_owner_any() or public.is_staff()) then
      raise exception 'not authorised to remove this photo';
    end if;
    update public.students set photo_url = null where id = p_student_id
      returning user_id into v_target_user;
    if v_target_user is not null then
      update public.users set photo_url = null where id = v_target_user;
    end if;
    delete from public.photo_approvals where student_id = p_student_id and status = 'pending';
  end if;
end $function$
;

