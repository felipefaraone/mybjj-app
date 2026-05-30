-- 66_bjj_start_date.sql
-- Optional "when did this student first start practising BJJ (anywhere)"
-- date column. Sits alongside the existing students.training_started_at
-- and joined-at / created_at metadata, and seeds the new "Started BJJ"
-- journey timeline entry + profile header "Training since" fallback.
-- Idempotent: IF NOT EXISTS guards re-runs.

alter table public.students add column if not exists bjj_start_date date;
