-- 123_promotions_single_source_history.sql
-- 5 September 2026
--
-- PURPOSE
-- Version the whole belt-history architecture, applied directly in the SQL
-- Editor over one day. Kept as one file because the pieces are meaningless
-- apart: the policies need the source column, the triggers need it to know what
-- to skip, and staff_id has no point without a check to keep it exclusive.
--
-- Captured EXACTLY as it runs in production (see the note in migration 109).
-- Depends on migration 122 (audit_log), which must exist first so these changes
-- are themselves recorded.
--
-- ============================================================================
-- WHY ANY OF THIS
-- ============================================================================
-- students.journey was a jsonb array written by FIVE uncoordinated paths, one of
-- which ran on every page load. Each wrote the whole array, so the last writer
-- won and silently erased the others. That is how the head instructor's timeline
-- was overwritten twice, and why he could not recognise his own dates.
--
-- The fix is not a better array. public.promotions was ALREADY the source of
-- truth for belts; the array was a copy, and a copy diverges — he had four belts
-- in the array and zero rows in promotions. The timeline now derives from this
-- table and the array is legacy. Same rule the class-history timeline settled on
-- in an earlier arc: the history lives in the promotions.
--
-- ============================================================================
-- source: WHO SAID SO
-- ============================================================================
-- 'academy'  — the academy recorded it, including history typed in retroactively
--              by an instructor.
-- 'declared' — the student's own account of what happened before they joined.
--
-- Only the student knows when they earned belts at another gym, and there are
-- 400 of them; nobody is typing that in for everyone. So they enter it
-- themselves, scoped by RLS to their own row and to dates before they joined.
--
-- The head instructor's rule, in his words: "if we add a stripe or belt in app,
-- they can't change it. Anything prior they can change." source is that
-- sentence, expressed as a column.
--
-- CRITICAL — DECLARED HISTORY MUST NOT MOVE THE GRADING CLOCK.
-- last_marker_date is what the eligibility gate counts from. If a student
-- declaring a belt from 2015 set the marker to 2015, their grade count would
-- reset to a date the academy never witnessed. Three places had to learn to skip
-- declared rows, and missing any one of them would have leaked through:
--   - promotions_recompute_trigger  (skips early)
--   - promotion_reset_grade_baseline (skips early)
--   - recompute_student_stats        (filters the MAX(date) itself — this one is
--     the subtle one: the triggers above are not the only callers, so blocking
--     them alone would still let a recompute from any other path pick up a
--     declared row)
--
-- ============================================================================
-- staff_id: INSTRUCTORS HAVE BELTS TOO
-- ============================================================================
-- promotions only accepted student_id, so an instructor without a student record
-- could not have a belt history at all — the academy owner's black belt and five
-- degrees existed nowhere. Adding staff_id was chosen over forcing every
-- instructor to also be a student: 4 of 17 do not train here, and giving them a
-- student row would put them in the roster, in class counts and in promotion
-- criteria they have no business being in.
--
-- The check keeps exactly one of the two set. A row belongs to a person, and a
-- person is either on the roster or on the staff list for this purpose.
--
-- promotions_write_staff_guard / promotions_update_staff_guard exist so a plain
-- instructor cannot record their OWN promotion — the same principle that stops
-- an instructor editing their own belt. Owners can, because someone has to.
--
-- TRAP, LEARNED THE HARD WAY: these two guards were originally ONE policy
-- declared FOR ALL. A RESTRICTIVE policy FOR ALL also restricts SELECT, and its
-- expression used `staff_id <> (subquery)`, which returns NULL rather than true
-- when the viewer is not staff at all. RLS treats NULL as deny. The result: no
-- student could see ANY staff promotion — the owner's timeline rendered empty
-- for every member, with nothing in the console. Split into INSERT and UPDATE,
-- and `<>` replaced with `is distinct from`, which never returns NULL.
--
-- ============================================================================
-- date_precision: DO NOT INVENT A DAY NOBODY CHOSE
-- ============================================================================
-- The trigger for all of this was a single line reading "Started BJJ · Jan 2009"
-- on a public profile. The instructor had entered a year; a month input stored
-- 2009-01-01; the screen rendered January. He did not recognise it, and he was
-- right not to.
--
-- Now the person picks how precisely they remember, and the timeline renders at
-- that precision: a bare year stays a bare year.

-- ---------------------------------------------------------------------------
-- COLUMNS
-- ---------------------------------------------------------------------------
alter table public.promotions
  add column if not exists source text not null default 'academy';
alter table public.promotions
  drop constraint if exists promotions_source_check;
alter table public.promotions
  add constraint promotions_source_check check (source in ('academy','declared'));

alter table public.promotions
  add column if not exists staff_id uuid references public.staff(id) on delete cascade;
alter table public.promotions
  drop constraint if exists promotions_subject_check;
alter table public.promotions
  add constraint promotions_subject_check check (num_nonnulls(student_id, staff_id) = 1);

alter table public.promotions
  add column if not exists date_precision text not null default 'day';
alter table public.promotions
  drop constraint if exists promotions_date_precision_check;
alter table public.promotions
  add constraint promotions_date_precision_check
  check (date_precision in ('day','month','year'));

create index if not exists promotions_source_idx on public.promotions (student_id, source);
create index if not exists promotions_staff_idx  on public.promotions (staff_id, date);

-- ---------------------------------------------------------------------------
-- TRIGGER FUNCTIONS — all three must skip declared rows
-- ---------------------------------------------------------------------------
create or replace function public.promotions_recompute_trigger()
 returns trigger
 language plpgsql
as $function$
DECLARE
  v_student_id uuid;
BEGIN
  -- Declared history is the student's own account of what happened before the
  -- app. It must never move last_marker_date or the class counts — those
  -- describe progression the app actually witnessed.
  IF coalesce(NEW.source, OLD.source, 'academy') = 'declared' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  v_student_id := COALESCE(NEW.student_id, OLD.student_id);
  -- staff promotions carry no student row and no attendance: nothing to recompute
  IF v_student_id IS NOT NULL THEN
    PERFORM public.recompute_student_stats(v_student_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$function$;

create or replace function public.promotion_reset_grade_baseline()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_sid uuid := coalesce(NEW.student_id, OLD.student_id);
begin
  if coalesce(NEW.source, OLD.source, 'academy') = 'declared' then
    return coalesce(NEW, OLD);
  end if;
  if v_sid is null then return coalesce(NEW, OLD); end if;
  update public.students set baseline_grade = 0 where id = v_sid;
  perform public.recompute_student_stats(v_sid);
  return coalesce(NEW, OLD);
end;
$function$;

create or replace function public.trg_notify_promotion_fn()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_user_id       uuid;
  v_student_name  text;
  v_student_prog  text;
  v_promoter_name text;
  v_title         text;
  v_body          text;
begin
  -- 112: historical/backfill entries (hidden=true) are records, not events -- never notify.
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
$function$;

-- The one that is easy to forget: this reads promotions directly, so filtering
-- only the triggers above would still let a declared row set the marker.
create or replace function public.recompute_student_stats(p_student_id uuid)
 returns void
 language plpgsql
 security definer
as $function$
DECLARE
  v_base_total numeric; v_base_grade numeric;
  v_real_total numeric; v_real_gi numeric; v_real_nogi numeric; v_real_grade numeric;
  v_real_gi_grade numeric; v_real_nogi_grade numeric;
  v_gi numeric; v_nogi numeric; v_total numeric; v_grade numeric;
  v_gi_grade numeric; v_nogi_grade numeric;
  v_last_marker_date date;
BEGIN
  SELECT COALESCE(baseline_total,0), COALESCE(baseline_grade,0)
    INTO v_base_total, v_base_grade
  FROM public.students WHERE id = p_student_id;

  -- source='academy' ONLY.
  SELECT MAX(date) INTO v_last_marker_date
  FROM public.promotions
  WHERE student_id = p_student_id
    AND coalesce(source,'academy') = 'academy';

  SELECT COALESCE(SUM(class_value),0) INTO v_real_total
  FROM public.attendance WHERE student_id=p_student_id AND status='present';

  SELECT COALESCE(SUM(class_value),0) INTO v_real_gi
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality='gi';

  SELECT COALESCE(SUM(class_value),0) INTO v_real_nogi
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality IN ('nogi','mma');

  -- 1 training DAY counts as the HIGHEST class_value that day (owner's rule).
  SELECT COALESCE(SUM(day_max),0) INTO v_real_grade
  FROM (
    SELECT class_date, MAX(class_value) AS day_max
    FROM public.attendance
    WHERE student_id=p_student_id AND status='present'
      AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date)
    GROUP BY class_date
  ) daily;

  SELECT COALESCE(SUM(class_value),0) INTO v_real_gi_grade
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality='gi'
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  SELECT COALESCE(SUM(class_value),0) INTO v_real_nogi_grade
  FROM public.attendance WHERE student_id=p_student_id AND status='present' AND modality IN ('nogi','mma')
    AND (v_last_marker_date IS NULL OR class_date > v_last_marker_date);

  v_gi    := v_real_gi;
  v_nogi  := v_real_nogi;
  v_total := v_base_total + v_real_total;

  v_grade      := v_base_grade + v_real_grade;
  v_gi_grade   := v_real_gi_grade;
  v_nogi_grade := v_real_nogi_grade;

  UPDATE public.students SET
    total=v_total, gi_classes=v_gi, nogi_classes=v_nogi,
    grade=v_grade, gi_grade=v_gi_grade, nogi_grade=v_nogi_grade,
    last_marker_date=v_last_marker_date
  WHERE id=p_student_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- POLICIES
-- ---------------------------------------------------------------------------

-- A staff promotion has no student row, so the existing select policies (which
-- all join students) never match it. Without this an instructor's own belt
-- history is invisible to everyone but an owner.
drop policy if exists promotions_select_staff on public.promotions;
create policy promotions_select_staff on public.promotions
for select using (
  (staff_id is not null)
  and (public.current_status() = 'approved')
  and ((public."current_role"() = any (array['student','instructor'])) or public.is_admin())
);

-- The student may only ever write source='declared', on their own row, dated
-- strictly before they joined. Everything else is the academy's.
drop policy if exists promotions_insert_declared on public.promotions;
create policy promotions_insert_declared on public.promotions
for insert with check (
  (source = 'declared')
  and (public.current_status() = 'approved')
  and (exists (
    select 1 from public.students s
    where s.id = promotions.student_id
      and s.user_id = auth.uid()
      and promotions.date < s.created_at::date
  ))
);

drop policy if exists promotions_update_declared on public.promotions;
create policy promotions_update_declared on public.promotions
for update using (
  (source = 'declared')
  and (exists (select 1 from public.students s
               where s.id = promotions.student_id and s.user_id = auth.uid()))
) with check (
  (source = 'declared')
  and (exists (select 1 from public.students s
               where s.id = promotions.student_id and s.user_id = auth.uid()
                 and promotions.date < s.created_at::date))
);

drop policy if exists promotions_delete_declared on public.promotions;
create policy promotions_delete_declared on public.promotions
for delete using (
  (source = 'declared')
  and (exists (select 1 from public.students s
               where s.id = promotions.student_id and s.user_id = auth.uid()))
);

-- Restrictive, and split by command on purpose — see the trap noted at the top.
drop policy if exists promotions_write_staff_guard on public.promotions;
create policy promotions_write_staff_guard on public.promotions
as restrictive
for insert
with check (
  (staff_id is null)
  or public.is_unit_owner_any()
  or (staff_id is distinct from (select st.id from public.staff st where st.user_id = auth.uid() limit 1))
);

drop policy if exists promotions_update_staff_guard on public.promotions;
create policy promotions_update_staff_guard on public.promotions
as restrictive
for update
using (
  (staff_id is null)
  or public.is_unit_owner_any()
  or (staff_id is distinct from (select st.id from public.staff st where st.user_id = auth.uid() limit 1))
) with check (
  (staff_id is null)
  or public.is_unit_owner_any()
  or (staff_id is distinct from (select st.id from public.staff st where st.user_id = auth.uid() limit 1))
);
