-- Migration 51 — Delete notes (staff.feedback jsonb) and feedback rows,
-- with notification cascade for the latter.
--
-- Two RPCs:
--   delete_staff_note(p_staff_id, p_note_created_at) — admin-only.
--     Filters the named note out of staff.feedback by matching
--     elem->>'created_at' (text key written by add_staff_note in
--     migration 50). Returns the updated staff row so the client can
--     merge it.
--
--   delete_feedback(p_feedback_id) — admin OR original author.
--     Author identity resolves via the caller's staff row
--     (staff.user_id = auth.uid()). Before the delete, dismisses any
--     notification(s) keyed to this feedback row (so the recipient's
--     bell doesn't keep advertising a deleted message).
--
-- Auto-verifies both RPCs exist at end of migration.

BEGIN;

-- 1. delete_staff_note
CREATE OR REPLACE FUNCTION public.delete_staff_note(
  p_staff_id          uuid,
  p_note_created_at   text
) RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.staff;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised: admin only';
  END IF;

  UPDATE public.staff SET
    feedback = COALESCE((
      SELECT jsonb_agg(elem)
      FROM jsonb_array_elements(COALESCE(feedback, '[]'::jsonb)) elem
      WHERE elem->>'created_at' IS DISTINCT FROM p_note_created_at
    ), '[]'::jsonb)
  WHERE id = p_staff_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff % not found', p_staff_id;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_staff_note(uuid, text) TO authenticated;

-- 2. delete_feedback
CREATE OR REPLACE FUNCTION public.delete_feedback(
  p_feedback_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_feedback        public.feedback%ROWTYPE;
  v_caller_staff_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT * INTO v_feedback FROM public.feedback WHERE id = p_feedback_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'feedback % not found', p_feedback_id;
  END IF;

  SELECT s.id INTO v_caller_staff_id
  FROM public.staff s
  WHERE s.user_id = auth.uid()
  LIMIT 1;

  IF NOT public.is_admin()
     AND v_feedback.instructor_id IS DISTINCT FROM v_caller_staff_id THEN
    RAISE EXCEPTION 'not authorised: must be admin or original author';
  END IF;

  -- Cascade dismiss any notification(s) advertising this feedback so
  -- the recipient's bell stops surfacing a deleted message. read_at is
  -- set if unset so the unread count drops on the next refresh.
  UPDATE public.notifications
     SET dismissed_at = now(),
         read_at      = COALESCE(read_at, now())
   WHERE related_entity_type = 'feedback'
     AND related_entity_id   = p_feedback_id
     AND dismissed_at IS NULL;

  DELETE FROM public.feedback WHERE id = p_feedback_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_feedback(uuid) TO authenticated;

-- 3. Verification
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('delete_staff_note','delete_feedback');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Migration 51: expected 2 RPCs (delete_staff_note, delete_feedback), found %', v_count;
  END IF;
  RAISE NOTICE 'Migration 51: both RPCs present.';
END $$;

COMMIT;
