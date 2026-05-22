-- Migration 52 — G14.2 Parent Architecture V1: schema
-- units contact columns + users.welcome_dismissed + students.medical_notes
-- Applied via Supabase SQL Editor. Idempotent.

ALTER TABLE units ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE units ADD COLUMN IF NOT EXISTS mobile_phone text;
ALTER TABLE units ADD COLUMN IF NOT EXISTS email text;

ALTER TABLE users ADD COLUMN IF NOT EXISTS welcome_dismissed boolean NOT NULL DEFAULT true;
ALTER TABLE users ALTER COLUMN welcome_dismissed SET DEFAULT false;

ALTER TABLE students ADD COLUMN IF NOT EXISTS medical_notes text;

UPDATE units SET
  phone        = COALESCE(phone, '(02) 8034 8157'),
  mobile_phone = COALESCE(mobile_phone, '0406 456 766'),
  email        = COALESCE(email, 'info@mybjj.com.au')
WHERE legacy_id = 'nb';
