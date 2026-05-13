-- =============================================================================
-- myBJJ V1 — Phase 4.5 (Edit class counts + Delete feedback)
-- Run AFTER 06_phase4.sql. Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- update_class_counts RPC
-- ---------------------------------------------------------------------------
-- Lets owner ("Head Professor") and black-belt instructors ("Professor")
-- overwrite a student's class counters. Coaches (non-black-belt instructors),
-- students, and parents are rejected with a permission error.
-- ---------------------------------------------------------------------------
create or replace function public.update_class_counts(
  p_legacy_id text,
  p_total     int,
  p_gi        int,
  p_nogi      int,
  p_grade     int,
  p_gi_grade  int
) returns public.students
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role    text := public.current_role();
  v_belt    text;
  v_student public.students;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_total < 0 or p_gi < 0 or p_nogi < 0 or p_grade < 0 or p_gi_grade < 0 then
    raise exception 'counters must be non-negative integers';
  end if;

  -- owner is always allowed; otherwise the caller must be a black-belt
  -- instructor (a "Professor" in myBJJ titling).
  if v_role <> 'owner' then
    if v_role not in ('admin','instructor') then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
    select s.belt into v_belt
      from public.staff s
      where s.user_id = auth.uid()
      limit 1;
    if v_belt is null or v_belt <> 'black' then
      raise exception 'not authorised: only owner or professor can edit class counts';
    end if;
  end if;

  update public.students set
    total        = p_total,
    gi_classes   = p_gi,
    nogi_classes = p_nogi,
    grade        = p_grade,
    gi_grade     = p_gi_grade
  where legacy_id = p_legacy_id
  returning * into v_student;

  if not found then
    raise exception 'student % not found', p_legacy_id;
  end if;

  return v_student;
end;
$$;

grant execute on function public.update_class_counts(text,int,int,int,int,int) to authenticated;

-- ---------------------------------------------------------------------------
-- feedback RLS: replace the broad write policy with insert/update/delete
-- separately so we can restrict DELETE per-role.
-- ---------------------------------------------------------------------------
drop policy if exists feedback_write  on public.feedback;
drop policy if exists feedback_insert on public.feedback;
drop policy if exists feedback_update on public.feedback;
drop policy if exists feedback_delete on public.feedback;

create policy feedback_insert on public.feedback
  for insert to authenticated
  with check (public.is_staff());

create policy feedback_update on public.feedback
  for update to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- Owner can delete any feedback. Instructors (Professor / Coach) can only
-- delete rows where the feedback.instructor_id points at THEIR own staff row.
create policy feedback_delete on public.feedback
  for delete to authenticated
  using (
    public.current_role() = 'owner'
    or instructor_id in (
      select s.id from public.staff s where s.user_id = auth.uid()
    )
  );
