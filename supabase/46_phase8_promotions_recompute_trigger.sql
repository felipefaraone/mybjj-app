-- Migration 46 — Promotion mutations auto-recompute student stats
-- Mirrors the existing trg_attendance_recompute pattern.
-- Fixes G9.1 evidence: post-promote, students.last_marker_date was stale (NULL or
-- yesterday's date) because doPromote does INSERT/UPDATE without explicit recompute.

CREATE OR REPLACE FUNCTION public.promotions_recompute_trigger()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_student_id uuid;
BEGIN
  -- COALESCE handles INSERT/UPDATE (NEW) and DELETE (OLD)
  v_student_id := COALESCE(NEW.student_id, OLD.student_id);
  IF v_student_id IS NOT NULL THEN
    PERFORM public.recompute_student_stats(v_student_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_promotions_recompute ON public.promotions;
CREATE TRIGGER trg_promotions_recompute
AFTER INSERT OR UPDATE OR DELETE ON public.promotions
FOR EACH ROW EXECUTE FUNCTION public.promotions_recompute_trigger();

-- Sanity check: function must not modify promotions, else infinite loop.
-- recompute_student_stats reads promotions for MAX(date), writes only to students.
-- Confirmed safe.

-- Backfill: recompute all students with at least one promotion to clean up stale
-- last_marker_date from pre-trigger history.
DO $$
DECLARE
  r record;
  cnt int := 0;
BEGIN
  FOR r IN SELECT DISTINCT student_id FROM public.promotions WHERE student_id IS NOT NULL
  LOOP
    PERFORM public.recompute_student_stats(r.student_id);
    cnt := cnt + 1;
  END LOOP;
  RAISE NOTICE 'Migration 46: backfilled recompute for % students with promotion history', cnt;
END $$;

-- Verification: count promotions per student vs cached last_marker_date freshness
DO $$
DECLARE
  v_stale int;
BEGIN
  SELECT COUNT(*) INTO v_stale
  FROM public.students s
  WHERE EXISTS (SELECT 1 FROM public.promotions p WHERE p.student_id = s.id)
    AND s.last_marker_date IS NULL;
  IF v_stale > 0 THEN
    RAISE NOTICE 'Migration 46: WARNING — % students still have NULL last_marker_date despite having promotions. Investigate.', v_stale;
  ELSE
    RAISE NOTICE 'Migration 46: OK — all students with promotions have last_marker_date populated.';
  END IF;
END $$;
