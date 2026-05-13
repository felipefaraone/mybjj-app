-- =============================================================================
-- myBJJ V1 — REAL Neutral Bay roster (Phase 4 prep)
-- Replaces the 52 fake students with 57 real Neutral Bay students. Keeps
-- units (15), staff (3 — Mario, Felipe, John), events (5), and
-- programme_weeks (4). The 7 fake promotions are dropped because they
-- referenced fake student UUIDs.
-- Run AFTER 08_schema_v3.sql. Safe to re-run (UPSERT on legacy_id).
-- =============================================================================

-- 1) Wipe rows that reference student UUIDs.
delete from public.attendance;     -- (empty after fresh seed)
delete from public.feedback;       -- (empty after fresh seed)
delete from public.promotions;     -- removes the 7 fake-student promos
delete from public.photo_approvals; -- no FK to students but tied to user_ids
                                    -- that referenced demo seeds; harmless if empty
delete from public.students;       -- wipes the 52 fake rows

-- 2) Insert the real roster (57 students). prog=adult for all except
--    Brandon and Aiden (kids program). Unit is Neutral Bay throughout.
insert into public.students
  (legacy_id, full_name, nickname, belt, degree, prog,
   total, gi_classes, nogi_classes, grade, gi_grade,
   initials, has_gi, gender, journey, feedback, unit_id) values
  ('jhn',   'John',         'The Half Guard Prince',    'black',  0, 'adult', 0,0,0,0,0, 'JO', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('ali',   'Alison',       'The Bully',                'blue',   2, 'adult', 0,0,0,0,0, 'AL', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('aar',   'Aaron',        'The Final Boss',           'blue',   4, 'adult', 0,0,0,0,0, 'AA', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('ada',   'Adam',         'The White Belt',           'brown',  4, 'adult', 0,0,0,0,0, 'AD', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('adr',   'Adriano',      'King of Brazil',           'white',  4, 'adult', 0,0,0,0,0, 'AR', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('agu',   'Agustin',      'The Chef',                 'blue',   0, 'adult', 0,0,0,0,0, 'AG', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('aln',   'Allen',        'In Absentia',              'white',  0, 'adult', 0,0,0,0,0, 'AN', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('bnv',   'Ben V',        'Big Ben',                  'blue',   0, 'adult', 0,0,0,0,0, 'BV', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('bng',   'Ben G',        'Benji',                    'brown',  0, 'adult', 0,0,0,0,0, 'BG', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('brd',   'Brenden',      'Not Brandon',              'brown',  0, 'adult', 0,0,0,0,0, 'BD', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('brk',   'Brock',        'Are you Brock Ashby?',     'blue',   0, 'adult', 0,0,0,0,0, 'BK', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('chr',   'Chris',        'Christopher',              'brown',  0, 'adult', 0,0,0,0,0, 'CH', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('cia',   'Ciaron',       'Daddy',                    'purple', 0, 'adult', 0,0,0,0,0, 'CI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dam',   'Damien',       'The Friday Night Warrior', 'blue',   0, 'adult', 0,0,0,0,0, 'DM', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dar',   'Darcy',        'D''arcey',                 'white',  0, 'adult', 0,0,0,0,0, 'DC', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dvd',   'David',        'Gayvid Smallwood',         'purple', 0, 'adult', 0,0,0,0,0, 'DV', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dig',   'Diggaj',       'The Cliche',               'blue',   0, 'adult', 0,0,0,0,0, 'DG', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('eri',   'Erika',        'Brandon''s Mum',           'white',  4, 'adult', 0,0,0,0,0, 'ER', true, 'f', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('fwb',   'Felipe',       'White Belt Felipe',        'white',  4, 'adult', 0,0,0,0,0, 'FE', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('ger',   'Gerhard',      'Ben''s Dad',               'purple', 0, 'adult', 0,0,0,0,0, 'GH', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('gra',   'Graeme',       'Black Belt Graeme',        'black',  0, 'adult', 0,0,0,0,0, 'GR', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('hay',   'Hayan',        'Good Alison',              'white',  0, 'adult', 0,0,0,0,0, 'HA', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('hea',   'Heather',      'White Alison',             'blue',   0, 'adult', 0,0,0,0,0, 'HE', true, 'f', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jck',   'Jack',         'Jordan Luhr',              'blue',   2, 'adult', 0,0,0,0,0, 'JK', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jks',   'Jackson',      'Merab',                    'blue',   0, 'adult', 0,0,0,0,0, 'JS', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jms',   'James T',      'Tebby',                    'white',  0, 'adult', 0,0,0,0,0, 'JT', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jay',   'Jay',          'J',                        'blue',   0, 'adult', 0,0,0,0,0, 'JY', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jim',   'Jimmy',        'The Degenerate',           'purple', 1, 'adult', 0,0,0,0,0, 'JI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jon',   'Jon',          'French Jon',               'purple', 0, 'adult', 0,0,0,0,0, 'JN', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jsh',   'Josh',         'Max from Wish',            'white',  2, 'adult', 0,0,0,0,0, 'JH', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('jp',    'JP',           'Jangus Pangus',            'white',  0, 'adult', 0,0,0,0,0, 'JP', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('lmg',   'Liam Garman',  'Big Liam',                 'white',  0, 'adult', 0,0,0,0,0, 'LG', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('lmi',   'Liam Gilroy',  'Liam',                     'blue',   0, 'adult', 0,0,0,0,0, 'LI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('lmt',   'Liam T',       'Asian Liam',               'blue',   0, 'adult', 0,0,0,0,0, 'LT', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('lng',   'Loong',        'Mr Unchokable',            'purple', 0, 'adult', 0,0,0,0,0, 'LO', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('lkp',   'Luke P',       'Big Luke',                 'black',  0, 'adult', 0,0,0,0,0, 'LP', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('mtn',   'Martin',       'Judo Martin',              'blue',   0, 'adult', 0,0,0,0,0, 'MA', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('mtl',   'Matt L',       'Christmas',                'white',  4, 'adult', 0,0,0,0,0, 'ML', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('mtf',   'Matt F',       'Camperdown Matt',          'white',  0, 'adult', 0,0,0,0,0, 'MF', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('max',   'Max',          'Qantas',                   'blue',   0, 'adult', 0,0,0,0,0, 'MX', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('mit',   'Mitch',        'Blue Black Belt',          'black',  2, 'adult', 0,0,0,0,0, 'MI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('nkn',   'Nick N',       'Nick Nishijima',           'blue',   0, 'adult', 0,0,0,0,0, 'NN', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('nko',   'Nick O',       'Big Nick O''Han',          'blue',   0, 'adult', 0,0,0,0,0, 'NO', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('nic',   'Nico',         'Alison''s Coach',          'brown',  2, 'adult', 0,0,0,0,0, 'NC', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('omr',   'Omar',          NULL,                      'black',  0, 'adult', 0,0,0,0,0, 'OM', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('pdr',   'Pedro',        'The Fake Purple Belt',     'purple', 0, 'adult', 0,0,0,0,0, 'PD', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('ril',   'Riley',        'Lazah Killer',             'white',  2, 'adult', 0,0,0,0,0, 'RI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('sax',   'Saxon',        'Suxon Balls',              'white',  0, 'adult', 0,0,0,0,0, 'SX', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('stp',   'Stephanie',     NULL,                      'purple', 0, 'adult', 0,0,0,0,0, 'ST', true, 'f', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('tim',   'Tim',          'Takedown Tim',             'white',  0, 'adult', 0,0,0,0,0, 'TI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('tom',   'Tommy',        'Gi is life',               'blue',   4, 'adult', 0,0,0,0,0, 'TM', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('wil',   'Will',         'Handsome Will',            'blue',   0, 'adult', 0,0,0,0,0, 'WI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('laz',   'Lazah',        'The Dofus',                'white',  4, 'adult', 0,0,0,0,0, 'LZ', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dnp',   'Dan P',        'No Relation to Luke P',    'blue',   0, 'adult', 0,0,0,0,0, 'DP', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('brn',   'Brandon',      'Pay Attention Brandon',    'yellow', 8, 'kids',  0,0,0,0,0, 'BR', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('dne',   'Dane',         'Brenden''s Dane',          'black',  0, 'adult', 0,0,0,0,0, 'DN', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb')),
  ('ade',   'Aiden',        'Annoying Brandon',         'white',  0, 'kids',  0,0,0,0,0, 'AI', true, 'm', '[]'::jsonb, '[]'::jsonb, (select id from public.units where legacy_id='nb'))
on conflict (legacy_id) do update set
  full_name=excluded.full_name, nickname=excluded.nickname,
  belt=excluded.belt, degree=excluded.degree, prog=excluded.prog,
  total=excluded.total, gi_classes=excluded.gi_classes, nogi_classes=excluded.nogi_classes,
  grade=excluded.grade, gi_grade=excluded.gi_grade,
  initials=excluded.initials, has_gi=excluded.has_gi, gender=excluded.gender,
  journey=excluded.journey, feedback=excluded.feedback, unit_id=excluded.unit_id;
