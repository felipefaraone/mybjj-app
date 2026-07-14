-- 94_trial_bookings_staff_write.sql
-- Leads are staff-only. Add the missing is_staff() gate to both RLS policies.
--
-- WHY: trial_bookings holds a lead's PII — first/last name, email, phone — plus
-- their booked class and waiver state. Both policies read
-- `is_admin() OR unit_id = current_unit()`, with NO staff check. current_unit() is
-- just "which unit is this session scoped to", not authority: any signed-in
-- STUDENT of the unit satisfied it. So any student could SELECT every lead's name,
-- email and phone, and UPDATE their trial_status. That is a privacy hole and a
-- data-integrity hole at once.
--
-- Authority is is_staff() (current_role() = 'instructor') or is_admin() (owns a
-- unit — migration 90). Add is_staff() to both, matching the Phase 3 UI, which
-- only ever surfaces trials inside staff roster / Trials views. The public
-- booking INSERT path is unaffected (it writes through the service-role Edge
-- Function, not anon RLS).
--
-- ALREADY APPLIED to the live DB (Supabase SQL Editor, never filed). Documentation
-- + staging-replay; idempotent (drop-if-exists + create).

drop policy if exists trial_bookings_staff_select on public.trial_bookings;
create policy trial_bookings_staff_select
  on public.trial_bookings for select
  to authenticated
  using (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()));

drop policy if exists trial_bookings_staff_update on public.trial_bookings;
create policy trial_bookings_staff_update
  on public.trial_bookings for update
  to authenticated
  using (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()))
  with check (public.is_admin() or (public.is_staff() and unit_id = public.current_unit()));
