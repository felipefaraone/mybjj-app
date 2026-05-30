-- 67_edit_student_self_bjj.sql
-- Extends edit_student_self RPC whitelist to accept bjj_start_date.

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
