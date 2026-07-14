-- 91_peer_visibility_from_relation.sql
-- Peer visibility derived from a RELATION, not from the role enum.
--
-- WHY: students_select and attendance_select granted "see the peers on the mat
-- with you" on current_role() = 'student'. A parent who ALSO trains has
-- role = 'parent', so that clause never fired: they stood in the adult class and
-- saw an EMPTY room, while the student beside them saw everyone. Same failure
-- shape as migrations 90 (ownership) and the class-list audience gate — a fact a
-- relation already knows, overridden by a singular enum.
--
-- The role enum was never the right question. The right question is a relation:
-- does this person have an ACTIVE, ADULT students row in THIS unit? That is true
-- for a student, for a training parent, and for a training instructor; false for
-- a parent who only drops their kid off. is_adult_peer_here() asks exactly that.
--
-- KIDS PRIVACY UNTOUCHED — recorded explicitly because it is the thing to get
-- wrong: prog = 'adult' stays in the visibility clause on BOTH sides. No child
-- became visible to anyone who is not staff or the child's own parent. This only
-- ever widens ADULT peer visibility, and only to other adults in the same unit.
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). Documentation
-- + staging-replay; idempotent (create or replace / drop-if-exists + create).

-- 1. The relation predicate. SECURITY DEFINER so it can read students without
--    recursing through students_select; STABLE so the planner can cache it per row.
create or replace function public.is_adult_peer_here()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.students s
     where s.user_id = auth.uid()
       and s.unit_id = public.current_unit()
       and s.prog = 'adult'
       and s.active is true
  )
$$;

-- 2. students_select — the peer clause now asks the relation (is_adult_peer_here)
--    instead of the enum ("current_role"() = 'student'). Self, own child, staff and
--    admin clauses are unchanged.
drop policy if exists students_select on public.students;
create policy students_select on public.students
  for select to authenticated
  using (
    public.is_admin()
    or (public.is_staff() and unit_id = public.current_unit())
    or (user_id = auth.uid())
    or (parent_user_id = auth.uid())
    or (unit_id = public.current_unit() and prog = 'adult' and public.is_adult_peer_here())
  );

-- 3. attendance_select — same swap inside the per-row EXISTS. A training adult sees
--    the 'going' list of adult classmates in their current unit; the status='going'
--    guard keeps confirmed/absent records staff-only, and prog='adult' keeps kids'
--    attendance out of peer view.
drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance
  for select to authenticated
  using (
    public.is_admin()
    or (public.is_staff() and attendance.unit_id = public.current_unit())
    or exists (
      select 1 from public.students s
       where s.id = attendance.student_id
         and (
           s.user_id = auth.uid()
           or s.parent_user_id = auth.uid()
           or (s.unit_id = public.current_unit()
               and s.prog = 'adult'
               and attendance.status = 'going'
               and public.is_adult_peer_here())
         )
    )
  );
