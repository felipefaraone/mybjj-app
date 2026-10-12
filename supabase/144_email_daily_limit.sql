-- ============================================================================
-- 144 — One automated email per address per Sydney day: the check
-- ============================================================================
--
-- WHY (12 Oct 2026)
-- joliecat888@gmail.com received two MIA emails in the same minute: M1 for one
-- child (last class 25 Sep) and M2 for a sibling (last class 18 Sep). Different
-- codes are correctly different emails, but two emails to one parent at once is
-- the flood the academy does not want. Rule decided: no address receives more
-- than ONE automated email per Sydney day, across all kinds. mia-emails applies
-- it first; trial-emails adopts it later with its own sibling grouping.
--
-- WHAT
-- public.email_sent_today(p_email, p_now) -> boolean. True when public.email_sends
-- (137) has, for that address (lowercased, trimmed), a row that WENT OUT or IS
-- BEING SENT on p_now's Sydney calendar day (sent_at when set, else created_at):
--   status 'sent'                          -> went out
--   status 'failed' AND error 'sending'    -> claimed, being sent right now (the
--                                             claim value both mia-emails and
--                                             trial-emails write before sending)
-- A 'failed' row with any other error did not go out; 'skipped' never sends.
-- EXEMPT (never count):
--   kind 'trial' with code '1' (booking confirmation) or '2' (day-before
--   reminder); the code is the last ':' segment of period_key
--   ('<session key>:<code>', 139). The two are expected, not marketing.
--   recipient info@mybjj.com.au (the team notes).
-- Closed to clients; service_role only. No table changes.
--
-- Rollback: 144_email_daily_limit_rollback.sql. Checks: 144_email_daily_limit_verify.sql.
-- ============================================================================

begin;

create or replace function public.email_sent_today(p_email text, p_now timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.email_sends es
     where lower(btrim(es.recipient_email::text)) = lower(btrim(p_email))
       and (es.status = 'sent' or (es.status = 'failed' and es.error = 'sending'))
       and (coalesce(es.sent_at, es.created_at) at time zone 'Australia/Sydney')::date
           = (p_now at time zone 'Australia/Sydney')::date
       -- exempt: trial booking confirmation ('1') and day-before reminder ('2')
       and not (es.kind = 'trial' and substring(es.period_key from '[^:]*$') in ('1', '2'))
       -- exempt: the team notes
       and lower(btrim(es.recipient_email::text)) <> 'info@mybjj.com.au'
  )
$$;

revoke all on function public.email_sent_today(text, timestamptz) from public, anon, authenticated;
grant execute on function public.email_sent_today(text, timestamptz) to service_role;

commit;
