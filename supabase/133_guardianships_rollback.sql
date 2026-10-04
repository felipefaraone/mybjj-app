-- 133_guardianships_rollback.sql
--
-- Undo 133_guardianships.sql. Restores the 8 policies and the 8 replaced
-- functions to the exact production definitions exported in
-- .local/guardianship_baseline.sql (pasted byte for byte), then drops the legacy
-- sync trigger, the guardian-student BEFORE DELETE trigger, the new functions
-- and public.guardianships.
--
-- DROPS DATA: every guardianship row goes with the table, including any a
-- staff member added after 133 ran. Export it first if that matters:
--   select * from public.guardianships;
-- The legacy students columns were never written by 133, so they are intact.
--
-- admin_change_user_email was not replaced by 133 and is not touched here.
-- The citext extension is left installed (other objects may come to use it).

begin;

-- 1. Policies back to baseline (they reference the new functions, so first).

drop policy if exists attendance_delete on public.attendance;
create policy attendance_delete on public.attendance
  as permissive for delete to authenticated
  using ((is_staff() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))));

drop policy if exists attendance_insert on public.attendance;
create policy attendance_insert on public.attendance
  as permissive for insert to authenticated
  with check ((is_staff() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))));

drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance
  as permissive for select to authenticated
  using ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = attendance.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR ((s.unit_id = current_unit()) AND (s.prog = 'adult'::text) AND (attendance.status = ANY (ARRAY['going'::text, 'present'::text])) AND is_adult_peer_here())))))));

drop policy if exists feedback_select on public.feedback;
create policy feedback_select on public.feedback
  as permissive for select to authenticated
  using ((is_admin() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = feedback.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR (is_staff() AND (s.unit_id = current_unit()))))))));

drop policy if exists hw_select on public.health_waivers;
create policy hw_select on public.health_waivers
  as permissive for select to authenticated
  using ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = health_waivers.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid())))))));

drop policy if exists waivers_read on storage.objects;
create policy waivers_read on storage.objects
  as permissive for select to authenticated
  using (((bucket_id = 'waivers'::text) AND (is_admin() OR (EXISTS ( SELECT 1
   FROM (health_waivers hw
     LEFT JOIN students s ON ((s.id = hw.student_id)))
  WHERE (((hw.id)::text = split_part(split_part(objects.name, '/'::text, 2), '.'::text, 1)) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()))))))));

drop policy if exists promotions_select on public.promotions;
create policy promotions_select on public.promotions
  as permissive for select to authenticated
  using ((is_admin() OR (EXISTS ( SELECT 1
   FROM students s
  WHERE ((s.id = promotions.student_id) AND ((s.user_id = auth.uid()) OR (s.parent_user_id = auth.uid()) OR (is_staff() AND (s.unit_id = current_unit()))))))));

drop policy if exists students_select on public.students;
create policy students_select on public.students
  as permissive for select to public
  using ((is_admin() OR (is_staff() AND (unit_id = current_unit())) OR (user_id = auth.uid()) OR (parent_user_id = auth.uid()) OR ((unit_id = current_unit()) AND (prog = 'adult'::text) AND is_adult_peer_here())));

-- 2. Functions back to baseline (also before the table they now read goes).

CREATE OR REPLACE FUNCTION public.claim_profile()
 RETURNS users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := auth.email();
  v_name text;
  v_existing public.users;
  v_wl public.whitelist;
  v_stu uuid;
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
         set status = 'approved',
             role = coalesce(v_wl.role, v_existing.role),
             unit_id = coalesce(v_wl.unit_id, v_existing.unit_id)
       where id = v_uid
       returning * into v_existing;
    end if;

    update public.staff
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    update public.students
       set user_id = v_uid
     where user_id is null
       and lower(email) = lower(v_email);

    -- Parent link — matches parent_email OR parent2_email.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    if v_wl.email is not null and v_wl.role = 'parent' and v_wl.student_id is not null then
      update public.students
         set parent_user_id = v_uid
       where id = v_wl.student_id
         and parent_user_id is null;
    end if;

    if v_existing.unit_id is null then
      update public.users u
         set unit_id = sub.unit_id
        from (
          select coalesce(
            (select unit_id from public.students where user_id = v_uid limit 1),
            (select unit_id from public.staff where user_id = v_uid limit 1),
            (select unit_id from public.students where parent_user_id = v_uid limit 1)
          ) as unit_id
        ) sub
       where u.id = v_uid
         and sub.unit_id is not null
       returning u.* into v_existing;
    end if;

    if v_existing.full_name is null or trim(v_existing.full_name) = '' then
      v_name := null;
      select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
        into v_name
        from public.students
       where lower(email) = lower(v_email)
       limit 1;
      if v_name is null or trim(v_name) = '' then
        select parent_name
          into v_name
          from public.students
         where lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email)
         limit 1;
      end if;
      if v_name is not null and trim(v_name) <> '' then
        update public.users
           set full_name = v_name
         where id = v_uid
           and (full_name is null or trim(full_name) = '')
         returning * into v_existing;
      end if;
    end if;

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;

    return v_existing;
  end if;

  v_name := coalesce(
    (auth.jwt() -> 'user_metadata' ->> 'full_name'),
    (auth.jwt() -> 'user_metadata' ->> 'name'),
    null
  );

  if v_name is null or trim(v_name) = '' then
    select nullif(trim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'')
      into v_name
      from public.students
     where lower(email) = lower(v_email)
     limit 1;
  end if;
  if v_name is null or trim(v_name) = '' then
    select parent_name
      into v_name
      from public.students
     where lower(parent_email) = lower(v_email)
        or lower(parent2_email) = lower(v_email)
     limit 1;
  end if;

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
       and lower(email) = lower(v_email);

    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );

    for v_stu in select id from public.students where user_id = v_uid loop
      perform public.seed_student_journey_if_empty(v_stu);
    end loop;
  else
    insert into public.users (id, email, role, status, full_name)
    values (v_uid, v_email, 'student', 'pending', v_name)
    returning * into v_existing;

    -- Migration 59: re-link orphan kids on first login even when the
    -- parent has no whitelist row.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and (lower(parent_email) = lower(v_email)
            or lower(parent2_email) = lower(v_email));

    -- Structured parent link (parent_student_id). See migration header.
    update public.students
       set parent_user_id = v_uid
     where parent_user_id is null
       and parent_student_id in (
         select id from public.students where user_id = v_uid
       );
  end if;

  return v_existing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.relink_orphan_kids_on_user_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Email path (unchanged).
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and (lower(parent_email)  = lower(new.email)
          or lower(parent2_email) = lower(new.email));

  -- Structured path (parent_student_id). Matches kids whose linked parent
  -- is the students row owned by this new user.
  update public.students
     set parent_user_id = new.id
   where parent_user_id is null
     and parent_student_id in (
       select id from public.students where user_id = new.id
     );

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_student_self(p_legacy_id text, p_payload jsonb)
 RETURNS students
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_id uuid;
  result    public.students;
BEGIN
  SELECT s.id INTO target_id
    FROM public.students s
   WHERE s.legacy_id = p_legacy_id
     AND (s.user_id = auth.uid() OR s.parent_user_id = auth.uid())
     AND s.active = true;

  IF target_id IS NULL THEN
    RAISE EXCEPTION 'Not authorized to edit this student profile' USING ERRCODE = '42501';
  END IF;

  UPDATE public.students
     SET
       full_name               = COALESCE(p_payload->>'full_name', full_name),
       first_name              = COALESCE(p_payload->>'first_name', first_name),
       last_name               = COALESCE(p_payload->>'last_name',  last_name),
       initials                = COALESCE(p_payload->>'initials', initials),
       date_of_birth           = COALESCE((p_payload->>'date_of_birth')::date, date_of_birth),
       bjj_start_date          = CASE WHEN p_payload ? 'bjj_start_date' THEN NULLIF(p_payload->>'bjj_start_date','')::date ELSE bjj_start_date END,
       training_started_at     = CASE WHEN p_payload ? 'training_started_at' THEN NULLIF(p_payload->>'training_started_at','')::date ELSE training_started_at END,
       phone                   = COALESCE(p_payload->>'phone', phone),
       gender                  = COALESCE(p_payload->>'gender', gender),
       weight_kg               = CASE WHEN p_payload ? 'weight_kg' THEN (p_payload->>'weight_kg')::integer ELSE weight_kg END,
       height_cm               = CASE WHEN p_payload ? 'height_cm' THEN (p_payload->>'height_cm')::integer ELSE height_cm END,
       emergency_contact_name  = COALESCE(p_payload->>'emergency_contact_name', emergency_contact_name),
       emergency_contact_phone = COALESCE(p_payload->>'emergency_contact_phone', emergency_contact_phone),
       has_mybjj_gi            = CASE WHEN p_payload ? 'has_mybjj_gi' THEN (p_payload->>'has_mybjj_gi')::boolean ELSE has_mybjj_gi END,
       social_handles          = CASE WHEN p_payload ? 'social_handles' THEN (p_payload->'social_handles') ELSE social_handles END
   WHERE id = target_id
   RETURNING * INTO result;

  RETURN result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.home_unit()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select unit_id from public.users    where id      = auth.uid()),
    (select unit_id from public.students where user_id = auth.uid() limit 1),
    (select unit_id from public.staff    where user_id = auth.uid() limit 1),
    (select unit_id from public.students where parent_user_id = auth.uid() limit 1)
  )
$function$
;

CREATE OR REPLACE FUNCTION public.send_admin_message(p_audience text, p_target_user_id uuid DEFAULT NULL::uuid, p_title text DEFAULT NULL::text, p_body text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller_unit   uuid;
  v_is_owner_any  boolean;
  v_recipient_ids uuid[];
  v_recipient_id  uuid;
  v_count         int;
  v_cap           constant int := 200;
begin
  -- Gating
  if not (public.is_staff() or public.is_unit_owner_any()) then
    raise exception 'send_admin_message: caller is not staff or owner';
  end if;

  -- Validate inputs
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'send_admin_message: title is required';
  end if;

  if p_audience not in ('all_unit', 'all_adults', 'all_kids', 'specific_user') then
    raise exception 'send_admin_message: invalid audience %', p_audience;
  end if;

  v_caller_unit  := public.current_unit();
  v_is_owner_any := public.is_unit_owner_any();

  -- Resolve recipients
  if p_audience = 'specific_user' then
    if p_target_user_id is null then
      raise exception 'send_admin_message: specific_user audience requires p_target_user_id';
    end if;
    if v_is_owner_any then
      -- Owner: any approved user
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id and u.status = 'approved';
    else
      -- Instructor: only own unit
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id
        and u.unit_id = v_caller_unit
        and u.status = 'approved';
    end if;

  elsif p_audience = 'all_unit' then
    -- V1: own/caller unit only. TODO: support multi-unit owner with p_unit_id param.
    select array_agg(u.id) into v_recipient_ids
    from public.users u
    where u.unit_id = v_caller_unit
      and u.status = 'approved';

  elsif p_audience = 'all_adults' then
    -- Users linked to adult students (excludes parents & kids).
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.user_id = u.id
    where s.prog = 'adult'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);

  elsif p_audience = 'all_kids' then
    -- Kids have no accounts: notify their parent users.
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.parent_user_id = u.id
    where s.prog = 'kids'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);
  end if;

  v_recipient_ids := coalesce(v_recipient_ids, array[]::uuid[]);
  v_count := coalesce(array_length(v_recipient_ids, 1), 0);

  if v_count = 0 then
    return 0;
  end if;

  if v_count > v_cap then
    raise exception 'send_admin_message: audience exceeds % recipients (got %)', v_cap, v_count;
  end if;

  -- Fan-out
  foreach v_recipient_id in array v_recipient_ids loop
    perform public.create_notification(
      p_user_id             := v_recipient_id,
      p_type                := 'admin_message',
      p_title               := p_title,
      p_body                := p_body,
      p_related_entity_type := 'admin_message',
      p_related_entity_id   := null,            -- no entity, so no dedupe
      p_metadata            := jsonb_build_object(
                                 'sent_by', auth.uid(),
                                 'audience', p_audience
                               ),
      p_check_prefs         := true             -- announcements honor opt-out
    );
  end loop;

  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_feedback_added_fn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id         uuid;
  v_student_name    text;
  v_student_prog    text;
  v_instructor_name text;
  v_body            text;
begin
  select
    coalesce(s.user_id, s.parent_user_id),
    s.full_name,
    s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s
  where s.id = NEW.student_id;

  -- Orphan student (no linked user/parent): skip silently
  if v_user_id is null then
    return NEW;
  end if;

  select coalesce(st.full_name, 'An instructor') into v_instructor_name
  from public.staff st
  where st.id = NEW.instructor_id;

  if v_student_prog = 'kids' then
    v_body := coalesce(v_instructor_name, 'An instructor')
              || ' left feedback for '
              || coalesce(v_student_name, 'your child') || '.';
  else
    v_body := coalesce(v_instructor_name, 'An instructor') || ' left you feedback.';
  end if;

  perform public.create_notification(
    p_user_id             := v_user_id,
    p_type                := 'feedback_received',
    p_title               := 'New feedback',
    p_body                := v_body,
    p_related_entity_type := 'feedback',
    p_related_entity_id   := NEW.id,
    p_metadata            := jsonb_build_object(
                               'student_id',    NEW.student_id,
                               'instructor_id', NEW.instructor_id
                             ),
    p_check_prefs         := true
  );

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_promotion_fn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid; v_student_name text; v_student_prog text;
  v_promoter_name text; v_title text; v_body text;
begin
  if NEW.hidden is true then return NEW; end if;
  -- staff promotions are records, not events for the student inbox
  if NEW.student_id is null then return NEW; end if;
  select coalesce(s.user_id, s.parent_user_id), s.full_name, s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s where s.id = NEW.student_id;
  if v_user_id is null then return NEW; end if;
  v_promoter_name := coalesce(NEW.promoted_by_name, 'Your instructor');
  if NEW.is_new_belt is true then
    v_title := 'New belt!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    else
      v_body := 'You were promoted to ' || coalesce(NEW.to_belt, 'a new belt') || ' by ' || v_promoter_name || '.';
    end if;
  else
    v_title := 'New stripe!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child') || ' earned a new stripe from ' || v_promoter_name || '.';
    else
      v_body := 'You earned a new stripe from ' || v_promoter_name || '.';
    end if;
  end if;
  perform public.create_notification(
    p_user_id := v_user_id, p_type := 'promotion', p_title := v_title, p_body := v_body,
    p_related_entity_type := 'promotion', p_related_entity_id := NEW.id,
    p_metadata := jsonb_build_object('student_id', NEW.student_id, 'from_belt', NEW.from_belt,
      'to_belt', NEW.to_belt, 'from_deg', NEW.from_deg, 'to_deg', NEW.to_deg, 'is_new_belt', NEW.is_new_belt),
    p_check_prefs := true);
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.whitelist_remove(p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := lower(btrim(coalesce(p_email,'')));
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not (public.is_unit_owner_any() or public.is_staff()) then
    raise exception 'not authorised to remove';
  end if;

  if v_email = '' then
    return;
  end if;

  if exists (
    select 1 from public.students s
    where s.active is true
      and ( lower(coalesce(s.email,'')) = v_email
         or lower(coalesce(s.parent_email,'')) = v_email )
  ) then
    return;
  end if;

  delete from public.whitelist where lower(email) = v_email;
end;
$function$
;

-- 3. New objects.
drop trigger if exists trg_guardianship_legacy_sync on public.students;
drop function if exists public.trg_guardianship_legacy_sync_fn();
drop trigger if exists trg_guardianship_student_delete on public.students;
drop function if exists public.trg_guardianship_student_delete_fn();
drop function if exists public._guardianship_revoke_orphans(public.students, public.students);
drop function if exists public._guardianship_row_matches(uuid, uuid[], uuid[], text[]);
drop function if exists public._guardianship_sync_student(uuid, text);
drop function if exists public._guardianship_link_user(uuid, uuid, uuid, text, boolean, text);
drop function if exists public._guardianship_add_pending_student(uuid, uuid, text, boolean, text);
drop function if exists public._guardianship_add_invite(uuid, text, text, text);
drop function if exists public._guardianship_claim(uuid, text);
drop function if exists public.is_guardian_of(uuid, text);
drop function if exists public.guardian_student_ids();
drop table if exists public.guardianships;

commit;
