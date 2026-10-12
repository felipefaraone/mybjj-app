-- 145_birthday_messages.sql
--
-- Birthday messages, varied by belt group, read by the app (Classes tab
-- greeting, staff birthdays panel, birthday share card). Read-only to clients:
-- authenticated may SELECT active rows; there are no write policies, and the
-- write/truncate privileges are revoked (TRUNCATE is not subject to RLS).
-- anon has no access at all. Edits are made by the owner in the dashboard / SQL.
--
-- Additive only: one new table, nothing existing changes.

begin;

create table if not exists public.birthday_messages (
  id          uuid primary key default gen_random_uuid(),
  belt_group  text not null check (belt_group in ('kids_beginner','kids_colour','white','blue','purple','brown','black')),
  body        text not null check (length(body) between 10 and 160),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table public.birthday_messages enable row level security;

drop policy if exists birthday_messages_select on public.birthday_messages;
create policy birthday_messages_select on public.birthday_messages
  as permissive for select to authenticated
  using (active is true);

revoke all on table public.birthday_messages from anon;
revoke insert, update, delete, truncate, references, trigger on table public.birthday_messages from authenticated;
grant select on table public.birthday_messages to authenticated;

-- Seed: 4 per group, 28 rows. Guarded so a re-run never duplicates.
insert into public.birthday_messages (belt_group, body)
select v.belt_group, v.body
  from (values
  ('kids_beginner', 'A whole year of new moves, new friends and lots of fun on the mats.'),
  ('kids_beginner', 'Every champion starts with their first steps on the mats.'),
  ('kids_beginner', 'More rolls, more laughs and more high fives this year.'),
  ('kids_beginner', 'Wishing a fantastic birthday from the whole team.'),
  ('kids_colour', 'Another year of growing skills and growing confidence.'),
  ('kids_colour', 'Strong on the mats, kind off them. Have an awesome birthday.'),
  ('kids_colour', 'Here''s to another year of learning, trying and never giving up.'),
  ('kids_colour', 'Every stripe was earned. Here''s to a great year ahead.'),
  ('white', 'Every black belt started right here. Here''s to another year of showing up.'),
  ('white', 'New year, new techniques, same mats.'),
  ('white', 'Keep showing up. The progress takes care of itself.'),
  ('white', 'Here''s to a year of great rolls and good training partners.'),
  ('blue', 'Another year of sharper guards and smarter escapes.'),
  ('blue', 'The fundamentals are clicking. Here''s to the year ahead.'),
  ('blue', 'Blue belt and still hungry to learn. Enjoy the day.'),
  ('blue', 'Here''s to another year of good rolls and great training partners.'),
  ('purple', 'The game keeps getting more creative. Here''s to another great year.'),
  ('purple', 'Here''s to another year of flow, timing and good rolls.'),
  ('purple', 'Halfway up the mountain and enjoying the climb.'),
  ('purple', 'Still curious, still learning. Enjoy the day.'),
  ('brown', 'Here''s to another year of leading by example on the mats.'),
  ('brown', 'Every class makes the game cleaner. Have a great birthday.'),
  ('brown', 'Brown belt calm, white belt curiosity. Here''s to the year ahead.'),
  ('brown', 'Sharpening the details, one class at a time. Enjoy the day.'),
  ('black', 'A black belt is a white belt who never stopped showing up.'),
  ('black', 'Thanks for everything given back on the mats. Have a great day.'),
  ('black', 'Here''s to another year of teaching, learning and rolling.'),
  ('black', 'Still a student of the game. Enjoy the day.')
  ) as v(belt_group, body)
 where not exists (select 1 from public.birthday_messages);

commit;
