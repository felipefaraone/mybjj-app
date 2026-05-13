-- =============================================================================
-- myBJJ V1 — SCHEMA v3
-- Adds nickname column + defensively ensures prog is text. Idempotent.
-- Run AFTER 04_schema_v2.sql.
-- =============================================================================

-- Defensive: 01_schema.sql declared students.prog as int, but the prototype
-- and seed both store 'adult' / 'kids'. The live database accepts the
-- strings, so this almost certainly converged to text already — the cast is
-- a no-op in that case and a one-time correction otherwise.
alter table public.students
  alter column prog type text using prog::text;
alter table public.students
  alter column prog set default 'adult';

-- Nickname (prototype roster has team nicknames per student).
alter table public.students
  add column if not exists nickname text;
