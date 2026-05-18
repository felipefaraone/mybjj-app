-- 44_phase8_edit_student_self_rpc.sql
-- RPC for student/parent self-edit. Mirrors edit_staff_self pattern.
-- SECURITY DEFINER bypasses RLS with explicit auth check on caller.

CREATE OR REPLACE FUNCTION public.edit_student_self(
  p_legacy_id text,
  p_payload jsonb
)
RETURNS public.students
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target_id uuid;
  result public.students;
BEGIN
  -- Resolve student and authorize caller (self OR parent of kid)
  SELECT s.id INTO target_id
  FROM public.students s
  WHERE s.legacy_id = p_legacy_id
    AND (s.user_id = auth.uid() OR s.parent_user_id = auth.uid())
    AND s.active = true;

  IF target_id IS NULL THEN
    RAISE EXCEPTION 'Not authorized to edit this student profile' USING ERRCODE = '42501';
  END IF;

  -- Update only personal fields. belt/degree/total/grade/journey/feedback are admin-only.
  UPDATE public.students
  SET
    full_name = COALESCE(p_payload->>'full_name', full_name),
    initials = COALESCE(p_payload->>'initials', initials),
    date_of_birth = COALESCE((p_payload->>'date_of_birth')::date, date_of_birth),
    phone = COALESCE(p_payload->>'phone', phone),
    gender = COALESCE(p_payload->>'gender', gender),
    weight_kg = CASE WHEN p_payload ? 'weight_kg' THEN (p_payload->>'weight_kg')::integer ELSE weight_kg END,
    height_cm = CASE WHEN p_payload ? 'height_cm' THEN (p_payload->>'height_cm')::integer ELSE height_cm END,
    emergency_contact_name = COALESCE(p_payload->>'emergency_contact_name', emergency_contact_name),
    emergency_contact_phone = COALESCE(p_payload->>'emergency_contact_phone', emergency_contact_phone)
  WHERE id = target_id
  RETURNING * INTO result;

  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_student_self(text, jsonb) TO authenticated;

-- Verify
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'edit_student_self' AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION 'edit_student_self not created';
  END IF;
  RAISE NOTICE 'edit_student_self created ✓';
END $$;
