-- ============================================================================
-- 129 — a promotion that promotes nothing must not be recordable
-- ============================================================================
--
-- WHAT HAPPENED
--
-- Four students had a promotion recorded that changed nothing: white belt, no
-- stripes, to white belt, no stripes. They were saved from the Promote modal,
-- which opens pre-seeded with the student's current belt and degree, so
-- pressing Save without touching the dropdowns writes exactly that.
--
-- The head instructor was doing the obvious thing — marking that someone had
-- started training. Promote is the only tool on that screen, so he used it.
--
-- The damage was invisible. The row sets last_marker_date, and grade counts
-- only class_date > that date. One student had trained once, on the day of the
-- empty promotion, and her card read 0 classes. Nothing on screen explained
-- why, and nothing in the app suggested the entry had caused it.
--
-- The existing duplicate-belt guard in savePromote only fires when the
-- direction is positive; a no-op has direction zero and walked straight
-- through.
--
-- THE CONSTRAINT
--
-- Belt or degree must actually change. Three exemptions:
--
--   type='correction'   fixing a date or a typo can legitimately leave both
--                       belt and degree alone
--   source='declared'   a student declaring their own pre-app history may
--                       record the belt they already hold
--   from_belt is null   an import or an origin row has nothing to compare
--
-- NOT VALID, DELIBERATELY
--
-- One legitimate row already violates this: an imported record stating "was at
-- white, 3rd stripe, on this date" rather than a transition. That is history
-- and is not being deleted to satisfy a new rule. NOT VALID leaves existing
-- rows alone and applies to every insert and update from here.
--
-- DATA FIXED IN THE SAME SESSION (recorded here, not reproducible)
--
-- 1. Four empty promotions deleted (backup: _bak_promotions_noop_20260905).
--    Their students' counts recovered to 7, 9, 1 and 2 classes, matching real
--    attendance. No class data was ever lost; only the count was cut. One of
--    them, Sarah Shim, had trained once and showed zero.
--
--      delete from public.promotions
--       where from_belt = to_belt
--         and coalesce(from_deg,0) = 0 and coalesce(to_deg,0) = 0
--         and type = 'stripe'
--         and student_id is not null;
--
--    Scoped narrowly on purpose: a fifth row matched the broad
--    "changes nothing" shape but was an imported record at white/3, not a
--    mistake, and was left alone.
--
-- 2. Six promotions that changed BELT were recorded with type='stripe'
--    (backup: _bak_promotions_type_20260905). The timeline renders the label
--    from the type, so it read the degree and produced "0th stripe" — a grade
--    that does not exist — where the belt name belonged. All six came from one
--    batch of backdated gradings entered on 23 August.
--
--      update public.promotions set type = 'belt'
--       where from_belt is distinct from to_belt
--         and type = 'stripe'
--         and from_belt is not null;
-- ============================================================================

alter table public.promotions
  add constraint promotions_must_change_something
  check (
    type = 'correction'
    or coalesce(source,'academy') = 'declared'
    or from_belt is null
    or from_belt is distinct from to_belt
    or coalesce(from_deg,0) is distinct from coalesce(to_deg,0)
  ) not valid;
