-- 68_week_cap.sql
-- Enforce max 5 programme weeks per (unit, month). The frontend already
-- hides "+Add" at 5 weeks; this BEFORE INSERT trigger is the DB safety net.
create or replace function enforce_week_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_count integer;
begin
  if NEW.unit_id is null or NEW.week_start is null then
    return NEW;
  end if;

  select count(*) into existing_count
  from programme_weeks
  where unit_id = NEW.unit_id
    and date_trunc('month', week_start) = date_trunc('month', NEW.week_start);

  if existing_count >= 5 then
    raise exception 'Week limit reached: a month can have at most 5 weeks.';
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_enforce_week_cap on programme_weeks;
create trigger trg_enforce_week_cap
  before insert on programme_weeks
  for each row
  execute function enforce_week_cap();
