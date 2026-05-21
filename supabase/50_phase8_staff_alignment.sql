-- Migration 50 — Staff edit alignment + head-instructor notes persistence.
-- Three changes:
--   1. CREATE OR REPLACE edit_staff_self: accept first_name, last_name,
--      has_mybjj_gi, social_handles. Recompute full_name = trim(concat_ws(' '
--      , new_first, new_last)) when either name field changes so admin
--      surfaces stay aligned with the self-edited row.
--   2. CREATE OR REPLACE edit_staff_admin: same new payload keys
--      (first_name, last_name, has_mybjj_gi, social_handles) plus a
--      mirror of the same full_name recompute logic.
--   3. CREATE add_staff_note(p_staff_id uuid, p_text text): admin-only
--      RPC that appends a {text, by, date, created_at} object to
--      staff.feedback jsonb. Replaces the in-memory G17.2a saveStaffFb
--      stub. Author resolved from public.users.full_name by auth.uid().
--
-- Auto-verifies all three RPCs exist with the expected signatures.

BEGIN;

-- 1. edit_staff_self — superset of 12_phase5_5 version.
CREATE OR REPLACE FUNCTION public.edit_staff_self(
  p_legacy_id text,
  p_payload   jsonb
) RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row       public.staff;
  v_new_first text;
  v_new_last  text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT * INTO v_row FROM public.staff WHERE legacy_id = p_legacy_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff % not found', p_legacy_id;
  END IF;
  IF v_row.user_id IS NULL OR v_row.user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorised: you can only edit your own staff profile';
  END IF;

  -- Resolve effective new first/last before the update so the
  -- recomputed full_name reflects the final pair (not the half-updated
  -- intermediate state).
  v_new_first := COALESCE(p_payload->>'first_name', v_row.first_name);
  v_new_last  := COALESCE(p_payload->>'last_name',  v_row.last_name);

  UPDATE public.staff SET
    first_name     = COALESCE(p_payload->>'first_name', first_name),
    last_name      = COALESCE(p_payload->>'last_name',  last_name),
    full_name      = CASE
                       WHEN p_payload ? 'first_name' OR p_payload ? 'last_name'
                         THEN btrim(concat_ws(' ', v_new_first, v_new_last))
                       ELSE COALESCE(p_payload->>'full_name', full_name)
                     END,
    initials       = COALESCE(p_payload->>'initials',  initials),
    has_mybjj_gi   = CASE WHEN p_payload ? 'has_mybjj_gi'
                          THEN (p_payload->>'has_mybjj_gi')::boolean
                          ELSE has_mybjj_gi END,
    social_handles = CASE WHEN p_payload ? 'social_handles'
                          THEN (p_payload->'social_handles')
                          ELSE social_handles END,
    journey        = CASE WHEN p_payload ? 'journey'
                          THEN (p_payload->'journey')
                          ELSE journey END
  WHERE legacy_id = p_legacy_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_staff_self(text, jsonb) TO authenticated;

-- 2. edit_staff_admin — superset of 39_phase8_rpc_role_cleanup version.
CREATE OR REPLACE FUNCTION public.edit_staff_admin(
  p_legacy_id text,
  p_payload   jsonb
) RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row       public.staff;
  v_unit_id   uuid;
  v_new_role  text;
  v_new_first text;
  v_new_last  text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_unit_owner_any() THEN
    RAISE EXCEPTION 'not authorised: owner only';
  END IF;

  SELECT * INTO v_row FROM public.staff WHERE legacy_id = p_legacy_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff % not found', p_legacy_id;
  END IF;

  IF p_payload ? 'unit_legacy_id' THEN
    SELECT id INTO v_unit_id FROM public.units WHERE legacy_id = p_payload->>'unit_legacy_id';
    IF v_unit_id IS NULL THEN
      RAISE EXCEPTION 'unit % not found', p_payload->>'unit_legacy_id';
    END IF;
  END IF;

  IF p_payload ? 'belt' AND (p_payload->>'belt') NOT IN ('white','blue','purple','brown','black') THEN
    RAISE EXCEPTION 'invalid belt';
  END IF;
  IF p_payload ? 'degree' AND ((p_payload->>'degree')::int < 0 OR (p_payload->>'degree')::int > 6) THEN
    RAISE EXCEPTION 'invalid degree';
  END IF;

  v_new_first := COALESCE(p_payload->>'first_name', v_row.first_name);
  v_new_last  := COALESCE(p_payload->>'last_name',  v_row.last_name);

  UPDATE public.staff SET
    first_name     = COALESCE(p_payload->>'first_name', first_name),
    last_name      = COALESCE(p_payload->>'last_name',  last_name),
    full_name      = CASE
                       WHEN p_payload ? 'first_name' OR p_payload ? 'last_name'
                         THEN btrim(concat_ws(' ', v_new_first, v_new_last))
                       ELSE COALESCE(p_payload->>'full_name', full_name)
                     END,
    initials       = COALESCE(p_payload->>'initials',  initials),
    belt           = COALESCE(p_payload->>'belt',      belt),
    degree         = COALESCE((p_payload->>'degree')::int, degree),
    unit_id        = COALESCE(v_unit_id, unit_id),
    role_title     = COALESCE(p_payload->>'role_title', role_title),
    has_mybjj_gi   = CASE WHEN p_payload ? 'has_mybjj_gi'
                          THEN (p_payload->>'has_mybjj_gi')::boolean
                          ELSE has_mybjj_gi END,
    social_handles = CASE WHEN p_payload ? 'social_handles'
                          THEN (p_payload->'social_handles')
                          ELSE social_handles END,
    journey        = CASE WHEN p_payload ? 'journey'
                          THEN (p_payload->'journey')
                          ELSE journey END
  WHERE legacy_id = p_legacy_id
  RETURNING * INTO v_row;

  -- Optional users.role write-through (same as migration 39).
  IF p_payload ? 'role' AND v_row.user_id IS NOT NULL THEN
    v_new_role := p_payload->>'role';
    IF v_new_role <> 'instructor' THEN
      RAISE EXCEPTION 'invalid role: must be instructor (post Batch 2A)';
    END IF;
    UPDATE public.users SET role = v_new_role WHERE id = v_row.user_id;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_staff_admin(text, jsonb) TO authenticated;

-- 3. add_staff_note — admin-only RPC. Appends to staff.feedback jsonb.
CREATE OR REPLACE FUNCTION public.add_staff_note(
  p_staff_id uuid,
  p_text     text
) RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row    public.staff;
  v_author text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised: admin only';
  END IF;
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RAISE EXCEPTION 'empty note';
  END IF;

  SELECT u.full_name INTO v_author FROM public.users u WHERE u.id = auth.uid();

  -- New rows prepended (G16b summary card reads index 0 as "latest").
  -- by  : human attribution string for the rendered card.
  -- date: "Mon YYYY" so the chip stays compact regardless of locale.
  UPDATE public.staff SET
    feedback = jsonb_build_array(
                 jsonb_build_object(
                   'text', p_text,
                   'by',   COALESCE(NULLIF(btrim(v_author), ''), 'Unknown'),
                   'date', to_char(now(), 'Mon YYYY'),
                   'created_at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                 )
               ) || COALESCE(feedback, '[]'::jsonb)
  WHERE id = p_staff_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff % not found', p_staff_id;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_staff_note(uuid, text) TO authenticated;

-- 4. Verification — all three RPCs exist with the expected signatures.
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('edit_staff_self', 'edit_staff_admin', 'add_staff_note');
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Migration 50: expected 3 RPCs (edit_staff_self, edit_staff_admin, add_staff_note), found %', v_count;
  END IF;
  RAISE NOTICE 'Migration 50: all 3 RPCs present.';
END $$;

COMMIT;
