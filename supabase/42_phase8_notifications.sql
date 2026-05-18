-- ============================================================
-- supabase/42_phase8_notifications.sql
-- Phase 8 — G1: Notifications real
-- Date: 18 May 2026
--
-- Purpose: Replace the hardcoded NOTIFS array in the frontend with a
-- real DB-backed notification system. Adds notifications table, RLS,
-- 7 RPCs (1 internal + 6 public), and 3 triggers (photo status,
-- feedback added, promotion added).
--
-- Idempotent. Safe to re-run.
-- ============================================================

-- ============================================================
-- 1. Table: notifications
-- ============================================================
create table if not exists public.notifications (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.users(id) on delete cascade,
  type                 text not null check (type in (
                         'photo_approved', 'photo_rejected',
                         'feedback_received', 'promotion',
                         'admin_message'
                       )),
  title                text not null,
  body                 text,
  related_entity_type  text check (related_entity_type in (
                         'photo_approval', 'feedback', 'promotion', 'admin_message'
                       )),
  related_entity_id    uuid,
  metadata             jsonb not null default '{}'::jsonb,
  read_at              timestamptz,
  dismissed_at         timestamptz,
  created_at           timestamptz not null default now()
);

-- ============================================================
-- 2. Indexes
-- ============================================================
create index if not exists idx_notifications_user_unread
  on public.notifications (user_id, read_at)
  where dismissed_at is null;

create index if not exists idx_notifications_user_created
  on public.notifications (user_id, created_at desc)
  where dismissed_at is null;

-- Dedupe lookup support (used by create_notification)
create index if not exists idx_notifications_related_entity
  on public.notifications (user_id, related_entity_type, related_entity_id)
  where related_entity_id is not null;

-- ============================================================
-- 3. Notification preferences column (jsonb)
--    NOTE: users.notification_preferences was added in migration 26.
--    The `if not exists` clause here is a safety no-op and serves as
--    documentation that this migration depends on the column.
-- ============================================================
alter table public.users
  add column if not exists notification_preferences jsonb not null default '{}'::jsonb;

-- ============================================================
-- 4. RLS
-- ============================================================
alter table public.notifications enable row level security;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- No INSERT policy: direct inserts blocked. All inserts go through
-- SECURITY DEFINER RPCs (create_notification, send_admin_message, triggers).
-- No DELETE policy: dismiss_notification sets dismissed_at instead.

-- ============================================================
-- 5. Helper: user_wants_notification_type
--    Maps notification.type -> notification_preferences jsonb key.
--    Opt-out model: missing key defaults to true.
-- ============================================================
create or replace function public.user_wants_notification_type(
  p_user_id uuid,
  p_type    text
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_type = 'feedback_received' then
      coalesce((u.notification_preferences->>'feedback')::boolean, true)
    when p_type = 'promotion' then
      coalesce((u.notification_preferences->>'promotions')::boolean, true)
    when p_type = 'admin_message' then
      coalesce((u.notification_preferences->>'announcements')::boolean, true)
    -- photo_approved / photo_rejected: always delivered (no opt-out)
    when p_type in ('photo_approved', 'photo_rejected') then true
    else true
  end
  from public.users u
  where u.id = p_user_id;
$$;

-- ============================================================
-- 6. RPC: create_notification (INTERNAL — SECURITY DEFINER, revoked from authenticated)
--    Used by triggers and send_admin_message. Not callable from frontend.
--    Dedupes on (user_id, type, related_entity_type, related_entity_id) when entity_id present.
-- ============================================================
create or replace function public.create_notification(
  p_user_id             uuid,
  p_type                text,
  p_title               text,
  p_body                text    default null,
  p_related_entity_type text    default null,
  p_related_entity_id   uuid    default null,
  p_metadata            jsonb   default '{}'::jsonb,
  p_check_prefs         boolean default true
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id          uuid;
  v_existing_id uuid;
begin
  -- Honor user prefs if requested
  if p_check_prefs and not public.user_wants_notification_type(p_user_id, p_type) then
    return null;
  end if;

  -- Dedupe: skip insert if a non-dismissed notification for the same entity already exists.
  -- Only applies when related_entity_id is set (admin messages always insert fresh).
  -- Dismissed notifications do NOT block re-creation — user expects to see updates after dismiss.
  if p_related_entity_id is not null and p_related_entity_type is not null then
    select id into v_existing_id
    from public.notifications
    where user_id = p_user_id
      and type = p_type
      and related_entity_type = p_related_entity_type
      and related_entity_id = p_related_entity_id
      and dismissed_at is null
    limit 1;

    if v_existing_id is not null then
      return v_existing_id;
    end if;
  end if;

  insert into public.notifications (
    user_id, type, title, body,
    related_entity_type, related_entity_id, metadata
  ) values (
    p_user_id, p_type, p_title, p_body,
    p_related_entity_type, p_related_entity_id, coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Block direct frontend calls to create_notification.
-- SECURITY DEFINER chain (e.g., send_admin_message -> create_notification) still works.
revoke all on function public.create_notification(uuid, text, text, text, text, uuid, jsonb, boolean) from public;
revoke all on function public.create_notification(uuid, text, text, text, text, uuid, jsonb, boolean) from anon;
revoke all on function public.create_notification(uuid, text, text, text, text, uuid, jsonb, boolean) from authenticated;

-- ============================================================
-- 7. RPC: list_my_notifications
-- ============================================================
create or replace function public.list_my_notifications(
  p_limit             int     default 50,
  p_include_dismissed boolean default false
) returns setof public.notifications
language sql
stable
security definer
set search_path = public
as $$
  select n.*
  from public.notifications n
  where n.user_id = auth.uid()
    and (p_include_dismissed or n.dismissed_at is null)
  order by n.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

-- ============================================================
-- 8. RPC: unread_notification_count
-- ============================================================
create or replace function public.unread_notification_count()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.notifications
  where user_id = auth.uid()
    and read_at is null
    and dismissed_at is null;
$$;

-- ============================================================
-- 9. RPC: mark_notification_read
-- ============================================================
create or replace function public.mark_notification_read(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_id and user_id = auth.uid();
$$;

-- ============================================================
-- 10. RPC: mark_all_notifications_read
-- ============================================================
create or replace function public.mark_all_notifications_read()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  update public.notifications
  set read_at = now()
  where user_id = auth.uid()
    and read_at is null
    and dismissed_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ============================================================
-- 11. RPC: dismiss_notification
--     Sets dismissed_at (and read_at if null). No hard delete.
-- ============================================================
create or replace function public.dismiss_notification(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications
  set dismissed_at = coalesce(dismissed_at, now()),
      read_at      = coalesce(read_at,      now())
  where id = p_id and user_id = auth.uid();
$$;

-- ============================================================
-- 12. RPC: send_admin_message
--     Gated by is_staff() OR is_unit_owner_any().
--     Audiences: all_unit, all_adults, all_kids, specific_user.
--     Cap: 200 recipients per call. Raises if exceeded.
-- ============================================================
create or replace function public.send_admin_message(
  p_audience       text,
  p_target_user_id uuid default null,
  p_title          text default null,
  p_body           text default null
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_unit   uuid;
  v_is_owner_any  boolean;
  v_recipient_ids uuid[];
  v_recipient_id  uuid;
  v_count         int;
  v_cap           constant int := 200;
begin
  -- Gating
  if not (public.is_staff() or public.is_unit_owner_any()) then
    raise exception 'send_admin_message: caller is not staff or owner';
  end if;

  -- Validate inputs
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'send_admin_message: title is required';
  end if;

  if p_audience not in ('all_unit', 'all_adults', 'all_kids', 'specific_user') then
    raise exception 'send_admin_message: invalid audience %', p_audience;
  end if;

  v_caller_unit  := public.current_unit();
  v_is_owner_any := public.is_unit_owner_any();

  -- Resolve recipients
  if p_audience = 'specific_user' then
    if p_target_user_id is null then
      raise exception 'send_admin_message: specific_user audience requires p_target_user_id';
    end if;
    if v_is_owner_any then
      -- Owner: any approved user
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id and u.status = 'approved';
    else
      -- Instructor: only own unit
      select array_agg(u.id) into v_recipient_ids
      from public.users u
      where u.id = p_target_user_id
        and u.unit_id = v_caller_unit
        and u.status = 'approved';
    end if;

  elsif p_audience = 'all_unit' then
    -- V1: own/caller unit only. TODO: support multi-unit owner with p_unit_id param.
    select array_agg(u.id) into v_recipient_ids
    from public.users u
    where u.unit_id = v_caller_unit
      and u.status = 'approved';

  elsif p_audience = 'all_adults' then
    -- Users linked to adult students (excludes parents & kids).
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.user_id = u.id
    where s.prog = 'adult'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);

  elsif p_audience = 'all_kids' then
    -- Kids have no accounts: notify their parent users.
    select array_agg(distinct u.id) into v_recipient_ids
    from public.users u
    join public.students s on s.parent_user_id = u.id
    where s.prog = 'kids'
      and s.active = true
      and u.status = 'approved'
      and (v_is_owner_any or u.unit_id = v_caller_unit);
  end if;

  v_recipient_ids := coalesce(v_recipient_ids, array[]::uuid[]);
  v_count := coalesce(array_length(v_recipient_ids, 1), 0);

  if v_count = 0 then
    return 0;
  end if;

  if v_count > v_cap then
    raise exception 'send_admin_message: audience exceeds % recipients (got %)', v_cap, v_count;
  end if;

  -- Fan-out
  foreach v_recipient_id in array v_recipient_ids loop
    perform public.create_notification(
      p_user_id             := v_recipient_id,
      p_type                := 'admin_message',
      p_title               := p_title,
      p_body                := p_body,
      p_related_entity_type := 'admin_message',
      p_related_entity_id   := null,            -- no entity, so no dedupe
      p_metadata            := jsonb_build_object(
                                 'sent_by', auth.uid(),
                                 'audience', p_audience
                               ),
      p_check_prefs         := true             -- announcements honor opt-out
    );
  end loop;

  return v_count;
end;
$$;

-- ============================================================
-- 13. Trigger: photo_approvals status change
--     Fires on transition into approved or rejected.
--     check_prefs = false (events about the user, no opt-out).
-- ============================================================
create or replace function public.trg_notify_photo_status_change_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
  v_body  text;
  v_type  text;
begin
  -- Skip no-op updates and transitions away from terminal states we don't care about
  if NEW.status not in ('approved', 'rejected') then
    return NEW;
  end if;
  if OLD.status is not distinct from NEW.status then
    return NEW;
  end if;

  if NEW.status = 'approved' then
    v_type  := 'photo_approved';
    v_title := 'Photo approved';
    v_body  := 'Your new profile photo is now visible.';
  else
    v_type  := 'photo_rejected';
    v_title := 'Photo rejected';
    v_body  := coalesce(
      'Reason: ' || nullif(trim(NEW.rejected_reason), ''),
      'Please upload a new photo.'
    );
  end if;

  perform public.create_notification(
    p_user_id             := NEW.user_id,
    p_type                := v_type,
    p_title               := v_title,
    p_body                := v_body,
    p_related_entity_type := 'photo_approval',
    p_related_entity_id   := NEW.id,
    p_metadata            := jsonb_build_object('status', NEW.status),
    p_check_prefs         := false
  );

  return NEW;
end;
$$;

drop trigger if exists trg_notify_photo_status_change on public.photo_approvals;
create trigger trg_notify_photo_status_change
  after update of status on public.photo_approvals
  for each row
  execute function public.trg_notify_photo_status_change_fn();

-- ============================================================
-- 14. Trigger: feedback added
--     Recipient: students.user_id (adults) OR students.parent_user_id (kids).
--     check_prefs = true (key 'feedback').
-- ============================================================
create or replace function public.trg_notify_feedback_added_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id         uuid;
  v_student_name    text;
  v_student_prog    text;
  v_instructor_name text;
  v_body            text;
begin
  select
    coalesce(s.user_id, s.parent_user_id),
    s.full_name,
    s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s
  where s.id = NEW.student_id;

  -- Orphan student (no linked user/parent): skip silently
  if v_user_id is null then
    return NEW;
  end if;

  select coalesce(st.full_name, 'An instructor') into v_instructor_name
  from public.staff st
  where st.id = NEW.instructor_id;

  if v_student_prog = 'kids' then
    v_body := coalesce(v_instructor_name, 'An instructor')
              || ' left feedback for '
              || coalesce(v_student_name, 'your child') || '.';
  else
    v_body := coalesce(v_instructor_name, 'An instructor') || ' left you feedback.';
  end if;

  perform public.create_notification(
    p_user_id             := v_user_id,
    p_type                := 'feedback_received',
    p_title               := 'New feedback',
    p_body                := v_body,
    p_related_entity_type := 'feedback',
    p_related_entity_id   := NEW.id,
    p_metadata            := jsonb_build_object(
                               'student_id',    NEW.student_id,
                               'instructor_id', NEW.instructor_id
                             ),
    p_check_prefs         := true
  );

  return NEW;
end;
$$;

drop trigger if exists trg_notify_feedback_added on public.feedback;
create trigger trg_notify_feedback_added
  after insert on public.feedback
  for each row
  execute function public.trg_notify_feedback_added_fn();

-- ============================================================
-- 15. Trigger: promotion added
--     Recipient: students.user_id (adults) OR students.parent_user_id (kids).
--     Title varies: "New belt!" if is_new_belt else "New stripe!".
--     check_prefs = true (key 'promotions').
-- ============================================================
create or replace function public.trg_notify_promotion_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid;
  v_student_name  text;
  v_student_prog  text;
  v_promoter_name text;
  v_title         text;
  v_body          text;
begin
  select
    coalesce(s.user_id, s.parent_user_id),
    s.full_name,
    s.prog
  into v_user_id, v_student_name, v_student_prog
  from public.students s
  where s.id = NEW.student_id;

  if v_user_id is null then
    return NEW;
  end if;

  v_promoter_name := coalesce(NEW.promoted_by_name, 'Your instructor');

  if NEW.is_new_belt is true then
    v_title := 'New belt!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child')
                || ' was promoted to ' || coalesce(NEW.to_belt, 'a new belt')
                || ' by ' || v_promoter_name || '.';
    else
      v_body := 'You were promoted to ' || coalesce(NEW.to_belt, 'a new belt')
                || ' by ' || v_promoter_name || '.';
    end if;
  else
    v_title := 'New stripe!';
    if v_student_prog = 'kids' then
      v_body := coalesce(v_student_name, 'Your child')
                || ' earned a new stripe from ' || v_promoter_name || '.';
    else
      v_body := 'You earned a new stripe from ' || v_promoter_name || '.';
    end if;
  end if;

  perform public.create_notification(
    p_user_id             := v_user_id,
    p_type                := 'promotion',
    p_title               := v_title,
    p_body                := v_body,
    p_related_entity_type := 'promotion',
    p_related_entity_id   := NEW.id,
    p_metadata            := jsonb_build_object(
                               'student_id',  NEW.student_id,
                               'from_belt',   NEW.from_belt,
                               'to_belt',     NEW.to_belt,
                               'from_deg',    NEW.from_deg,
                               'to_deg',      NEW.to_deg,
                               'is_new_belt', NEW.is_new_belt
                             ),
    p_check_prefs         := true
  );

  return NEW;
end;
$$;

drop trigger if exists trg_notify_promotion on public.promotions;
create trigger trg_notify_promotion
  after insert on public.promotions
  for each row
  execute function public.trg_notify_promotion_fn();

-- ============================================================
-- 16. Grants — public-callable RPCs
-- ============================================================
grant execute on function public.list_my_notifications(int, boolean)            to authenticated;
grant execute on function public.unread_notification_count()                    to authenticated;
grant execute on function public.mark_notification_read(uuid)                   to authenticated;
grant execute on function public.mark_all_notifications_read()                  to authenticated;
grant execute on function public.dismiss_notification(uuid)                     to authenticated;
grant execute on function public.send_admin_message(text, uuid, text, text)     to authenticated;
-- user_wants_notification_type is read-only helper, safe to expose:
grant execute on function public.user_wants_notification_type(uuid, text)       to authenticated;

-- ============================================================
-- 17. Sanity assertion
-- ============================================================
do $$
declare
  v_table_count   int;
  v_rpc_count     int;
  v_trigger_count int;
  v_policy_count  int;
  v_index_count   int;
  v_col_count     int;
begin
  -- Table
  select count(*) into v_table_count
  from pg_tables
  where schemaname = 'public' and tablename = 'notifications';
  if v_table_count <> 1 then
    raise exception 'sanity check failed: notifications table not created (count=%)', v_table_count;
  end if;

  -- RPCs: 6 public + 1 internal + 1 helper = 8
  select count(*) into v_rpc_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'create_notification', 'list_my_notifications',
      'unread_notification_count', 'mark_notification_read',
      'mark_all_notifications_read', 'dismiss_notification',
      'send_admin_message', 'user_wants_notification_type'
    );
  if v_rpc_count <> 8 then
    raise exception 'sanity check failed: expected 8 RPCs, found %', v_rpc_count;
  end if;

  -- Triggers
  select count(*) into v_trigger_count
  from pg_trigger
  where tgname in (
    'trg_notify_photo_status_change',
    'trg_notify_feedback_added',
    'trg_notify_promotion'
  );
  if v_trigger_count <> 3 then
    raise exception 'sanity check failed: expected 3 triggers, found %', v_trigger_count;
  end if;

  -- RLS policies
  select count(*) into v_policy_count
  from pg_policies
  where schemaname = 'public' and tablename = 'notifications';
  if v_policy_count <> 2 then
    raise exception 'sanity check failed: expected 2 RLS policies (select_own, update_own), found %', v_policy_count;
  end if;

  -- Indexes
  select count(*) into v_index_count
  from pg_indexes
  where schemaname = 'public'
    and tablename = 'notifications'
    and indexname in (
      'idx_notifications_user_unread',
      'idx_notifications_user_created',
      'idx_notifications_related_entity'
    );
  if v_index_count <> 3 then
    raise exception 'sanity check failed: expected 3 indexes, found %', v_index_count;
  end if;

  -- notification_preferences column
  select count(*) into v_col_count
  from information_schema.columns
  where table_schema = 'public'
    and table_name   = 'users'
    and column_name  = 'notification_preferences';
  if v_col_count <> 1 then
    raise exception 'sanity check failed: users.notification_preferences column missing';
  end if;

  raise notice '✓ notifications table created';
  raise notice '✓ % RPCs created', v_rpc_count;
  raise notice '   - public:   list_my_notifications, unread_notification_count, mark_notification_read,';
  raise notice '              mark_all_notifications_read, dismiss_notification, send_admin_message';
  raise notice '   - helper:   user_wants_notification_type';
  raise notice '   - internal: create_notification (revoked from authenticated)';
  raise notice '✓ % triggers created (photo_status_change, feedback_added, promotion)', v_trigger_count;
  raise notice '✓ % RLS policies (select_own, update_own; no INSERT/DELETE policies — by design)', v_policy_count;
  raise notice '✓ % indexes', v_index_count;
  raise notice '✓ users.notification_preferences jsonb column ensured';
  raise notice '✓ send_admin_message cap = 200 recipients (raises exception above)';
  raise notice '';
  raise notice '✓ migration 42 complete';
end $$;
