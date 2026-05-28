-- 58_phase8_kid_creation_link_parent.sql
-- One-off backfill: link existing students rows to users when the
-- parent's email already matches a registered user. Going forward, new
-- kid creation sets parent_user_id in the same end-to-end flow on the
-- client (index.html `submitAddStu` follow-up update after the INSERT).
--
-- Idempotent: only fills where parent_user_id IS NULL.

-- Before / after row counts logged via psql RAISE NOTICE.
do $$
declare
  v_before int;
  v_after  int;
  v_linked int;
begin
  select count(*) into v_before
    from public.students
    where parent_user_id is null and parent_email is not null;

  update public.students s
     set parent_user_id = u.id
    from public.users u
   where s.parent_user_id is null
     and s.parent_email is not null
     and lower(u.email) = lower(s.parent_email);

  get diagnostics v_linked = row_count;

  select count(*) into v_after
    from public.students
    where parent_user_id is null and parent_email is not null;

  raise notice 'Migration 58 — parent_user_id backfill';
  raise notice '  unlinked before: %', v_before;
  raise notice '  rows linked    : %', v_linked;
  raise notice '  unlinked after : %', v_after;
end $$;
