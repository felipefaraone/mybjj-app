-- 99_parent_student_link.sql
-- Structured parent-child linking. Links a kid to a parent by the parent's
-- students row id, independent of whether the parent has logged in.
-- Applied live in the Supabase editor on 2026-07-16; versioned after the fact.

alter table public.students
  add column if not exists parent_student_id uuid references public.students(id) on delete set null;

alter table public.students
  add column if not exists parent2_student_id uuid references public.students(id) on delete set null;
