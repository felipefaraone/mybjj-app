-- =============================================================================
-- myBJJ V1 — Phase 8 follow-up — notification_preferences column
-- Run AFTER 25_phase8_lastname_placeholder.sql. Safe to re-run.
--
-- Persists the toggles shown in Side panel → Notification preferences.
-- Stored as a jsonb blob so we can add categories without a schema
-- change. The existing users_update_self RLS already covers self
-- writes, so no policy change.
-- =============================================================================

alter table public.users
  add column if not exists notification_preferences jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
-- select column_name, data_type, column_default
--   from information_schema.columns
--  where table_schema='public' and table_name='users'
--    and column_name='notification_preferences';
