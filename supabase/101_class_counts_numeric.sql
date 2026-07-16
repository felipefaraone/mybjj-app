-- 101_class_counts_numeric.sql
-- update_class_counts: widen the five count params from integer to numeric.
--
-- WHY: attendance now records FRACTIONAL presence (Full 1.00, Partial 0.50,
-- Brief 0.25) and students.total / gi_classes / nogi_classes / grade / gi_grade
-- are numeric(scale 2). The RPC still declared its params as `int`, so PostgREST
-- rejected any fractional payload with:
--     invalid input syntax for type integer: "4.5"
-- Widening the params to `numeric` lets the manual "Edit class counts" modal
-- (and any fractional caller) persist decimals. The BODY is unchanged from
-- migration 40 — same auth check, non-negative check, owner-or-black-belt
-- authorization, the UPDATE on public.students, and the not-found guard.
--
-- Because the parameter TYPES change, the int-signature overload must be dropped
-- first (create-or-replace can't change a function's argument types in place).
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor) on 2026-07-16; this file
-- is documentation + staging-replay. Idempotent: drop-if-exists + create-or-replace.

drop function if exists public.update_class_counts(text,integer,integer,integer,integer,integer);

create or replace function public.update_class_counts(
  p_legacy_id text,
  p_total     numeric,
  p_gi        numeric,
  p_nogi      numeric,
  p_grade     numeric,
  p_gi_grade  numeric
) returns public.students
language plpgsql
security definer
set search_path = public
as $$
declare
  v_belt    text;
  v_student public.students;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_total < 0 or p_gi < 0 or p_nogi < 0 or p_grade < 0 or p_gi_grade < 0 then
    raise exception 'counters must be non-negative integers';
  end if;

  -- Owner is always allowed; otherwise the caller must be a black-belt
  -- instructor (a "Professor" in myBJJ titling).
  if not public.is_unit_owner_any() then
    if not public.is_staff() then
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

grant execute on function public.update_class_counts(text,numeric,numeric,numeric,numeric,numeric) to authenticated;
