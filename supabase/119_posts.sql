-- 119_posts.sql
-- 5 September 2026
--
-- PURPOSE
-- Version public.posts, applied directly in the SQL Editor. Staff-written Wall
-- posts, plus the automatic class-milestone posts that share the table.
--
-- Captured EXACTLY as it runs in production (see the note in migration 109).
--
-- WHY A TABLE AND NOT DERIVED
-- The Wall feed was built entirely from PROMOTION_LOG and STUDENTS — every card
-- was something the app already knew. A post someone WRITES has no other source,
-- so it needs storage. Everything else about the feed still derives.
--
-- NO DELETE POLICY, ON PURPOSE
-- Removal is active=false. A public post deleted by accident is unrecoverable
-- for the user and trivial for the database, and the file's own convention is
-- soft delete everywhere.
--
-- THE TRAP THAT COST A ROUND: posts_select requires active IS TRUE, and Postgres
-- applies a SELECT policy as an implicit WITH CHECK on the row an UPDATE
-- produces. So setting active=false is precisely the update that can never
-- satisfy it — removal returns 42501 "new row violates row-level security
-- policy" even for the author. That is why removal goes through the
-- set_post_active SECURITY DEFINER function (migration 121) instead of a
-- direct PATCH. Editing was never affected: the row stays active.
--
-- UNIT SCOPE IS ENFORCED TWICE, DELIBERATELY
-- posts_select allows is_unit_owner_any(), so an owner of both units receives
-- both units' posts whatever the header picker says. The client filters again by
-- the selected unit. RLS answers "what may you see"; the picker answers "what do
-- you want to see now". Two questions, two filters.

create table if not exists public.posts (
  id                 uuid primary key default gen_random_uuid(),
  unit_id            uuid not null references public.units(id) on delete restrict,
  author_user_id     uuid references public.users(id) on delete set null,
  author_name        text,
  body               text not null check (length(btrim(body)) between 1 and 2000),
  photo_path         text,
  created_at         timestamptz not null default now(),
  edited_at          timestamptz,
  active             boolean not null default true,
  kind               text not null default 'manual'
                       check (kind in ('manual','milestone')),
  subject_student_id uuid references public.students(id) on delete set null,
  milestone          integer
);

create index if not exists posts_feed_idx
  on public.posts using btree (unit_id, active, created_at desc);

-- One milestone per student per number, ever. The trigger that writes these
-- (migration 122) is idempotent on this index: a class_value corrected after the
-- fact can push a total back and forth across a threshold, and without this the
-- Wall would celebrate the same 50th class twice.
create unique index if not exists posts_milestone_uniq
  on public.posts using btree (subject_student_id, milestone)
  where (kind = 'milestone');

alter table public.posts enable row level security;

drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts
for select using (
  (active is true)
  and (public.current_status() = 'approved')
  and ((public."current_role"() = any (array['student','instructor'])) or public.is_admin())
  and (public.is_unit_owner_any() or (unit_id = public.current_unit()))
);

drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts
for insert with check (
  public.is_staff()
  and (author_user_id = auth.uid())
  and (public.is_unit_owner_any() or (unit_id = public.current_unit()))
);

-- is_staff() is not optional here. Authorship alone used to be enough, which
-- meant anyone MOVED FROM STAFF TO STUDENT kept edit and remove on the posts
-- they had written. Writing posts is staff-only, so managing them is too.
drop policy if exists posts_update on public.posts;
create policy posts_update on public.posts
for update using (
  public.is_staff()
  and ((author_user_id = auth.uid()) or public.is_admin() or public.is_unit_owner_any())
) with check (
  public.is_staff()
  and ((author_user_id = auth.uid()) or public.is_admin() or public.is_unit_owner_any())
);
