-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — rename "Started training" → "Joined myBJJ app"
-- Run AFTER 20_phase8_photo_rls.sql. Safe to re-run.
--
-- The auto-generated journey seed in migration 19 used the label
-- "Started training", which reads as the date the student first stepped
-- on a mat. For pilot students who'd been training for years before the
-- app existed, that's plainly wrong. The entry represents joining the
-- app — rename it.
--
-- What this migration does:
--   1. Replaces seed_student_journey_if_empty with the new label so any
--      future first sign-in writes "Joined myBJJ app".
--   2. Walks existing students.journey arrays and rewrites only the
--      entries that look auto-generated (label="Started training",
--      classes=0, done=true) — leaves the seed's "Started BJJ" entries
--      (real-history milestones with non-zero class counts and named
--      dates) untouched.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Replace the helper. Same shape as migration 19's version, new label.
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
-- 2. Back-fill: rewrite the label inside existing journey entries that
--    match the auto-generated signature. The WHERE clause's `@>`
--    containment check makes the update affect only rows that actually
--    contain such an entry, so re-running is a no-op.
-- ---------------------------------------------------------------------------
update public.students s
   set journey = (
     select jsonb_agg(
       case
         when elem @> '{"label":"Started training","classes":0,"done":true}'::jsonb
           then jsonb_set(elem, '{label}', '"Joined myBJJ app"'::jsonb)
         else elem
       end
       order by ord
     )
       from jsonb_array_elements(s.journey) with ordinality as t(elem, ord)
   )
 where s.journey @> '[{"label":"Started training","classes":0,"done":true}]'::jsonb;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select full_name,
--        jsonb_path_query_array(journey, '$[*].label') as labels
--   from public.students
--  where journey @> '[{"label":"Joined myBJJ app"}]'::jsonb;
-- select count(*) as still_using_old_label
--   from public.students
--  where journey @> '[{"label":"Started training","classes":0,"done":true}]'::jsonb;
