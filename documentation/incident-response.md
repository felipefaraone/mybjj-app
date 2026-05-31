# myBJJ Incident Response Plan

**Owner:** Felipe Faraone (sole developer / sole admin)
**Last updated:** 31 May 2026
**Purpose:** What to do when something goes wrong with personal data held in the myBJJ app.

This document exists to satisfy our obligations under the **Notifiable Data Breaches (NDB) scheme** (Privacy Act 1988, Part IIIC) and to remove improvisation from the response when an incident happens. It is a runbook, not a policy. When something happens, open this file and follow the steps.

---

## 1. What counts as an incident

An incident is any event that could compromise the confidentiality, integrity, or availability of personal information held in the myBJJ app. Concrete examples:

| Scenario | Trigger |
|---|---|
| **RLS policy bug** | A user reports seeing data that should not be visible to them (cross-unit data, kid data visible to non-parent, etc.) |
| **Compromised admin account** | The `admin.mybjj@gmail.com` password is leaked, phished, or used from an unknown device |
| **Compromised instructor / student account** | Same as above for any user; risk is lower but still a potential breach |
| **Lost hardware** | Mac or device containing local snapshots, credentials, or session tokens is lost or stolen |
| **Repo accidentally public** | `felipefaraone/mybjj-app` is flipped to public with the `CREDENTIALS` file or secrets inside |
| **Phishing / credential leak** | Supabase dashboard password, GitHub credentials, or service-role keys are leaked |
| **Migration error** | A SQL migration deletes or exposes more data than intended |
| **Storage bucket exposure** | A bucket misconfiguration causes private files to become listable / fetchable without auth |
| **Third-party breach** | Supabase or GitHub announces a breach affecting tenants |

If you're unsure whether something counts, **treat it as an incident and follow the steps anyway**. False alarms are cheap. Skipped notifications under the NDB scheme are not.

---

## 2. First response — Contain (first 15 minutes)

Goal: stop the bleeding. Do not yet worry about who was affected or whether to notify — that's section 3 and 4. Just **contain**.

### 2a. Acknowledge

Note the time you became aware. The NDB clock starts ticking from here. Write it down (in this file's section 5 log, or any text file — you'll need it later).

### 2b. Contain based on incident type

| Incident | Immediate steps |
|---|---|
| **RLS bug / data exposure via app** | 1. Identify the bug in code or RLS. 2. Roll back to last known good commit if a recent deploy caused it (`git revert HEAD; git push`). 3. Or push hotfix. 4. Bump SW to force clients to load fixed version. 5. Do NOT delete logs — you'll need them for assessment. |
| **Compromised account** | 1. In Supabase Dashboard → Authentication → Users, sign out all sessions for that user. 2. Force password reset. 3. If admin-level, rotate the service-role key and all API keys. |
| **Lost device** | 1. Sign out of all Supabase dashboard sessions from another device. 2. Rotate service-role key. 3. Change GitHub password + invalidate active sessions. 4. Change Supabase dashboard password. |
| **Repo went public with secrets** | 1. Immediately revoke every secret in the file (Supabase keys, DB password, any token). 2. Rotate everything. 3. Flip repo back to private. 4. Force-push history without the secret (`git filter-repo` or contact GitHub support to purge cache). |
| **Phishing / credential leak** | Same as compromised account, treat as if attacker has full access until proven otherwise. |
| **Migration error** | 1. Stop further migrations. 2. Restore from latest snapshot in `~/mybjj-backups/` if recoverable. 3. If not recoverable, document what was lost. |
| **Storage bucket exposure** | 1. Flip bucket to private via Supabase Dashboard. 2. Audit access logs (Supabase logs section) to estimate scope. |
| **Third-party breach (Supabase / GitHub)** | 1. Read their public disclosure. 2. Follow their guidance (rotate keys, etc.). 3. Skip to section 3 to assess myBJJ exposure. |

### 2c. Preserve evidence

Do NOT delete anything yet. Logs, code, RLS policies, Supabase activity — you may need them to assess scope. Take screenshots of dashboards before changes auto-purge. Save current state of relevant tables as a snapshot:

```bash
PGPASSWORD='9527@Mybjjapp' pg_dump -h aws-1-ap-southeast-2.pooler.supabase.com -p 5432 \
  -U postgres.dcilltzgegqsrgatskhz -d postgres \
  > ~/mybjj-backups/incident-$(date +%Y%m%d-%H%M%S).sql
```

---

## 3. Assess — Is this an eligible data breach?

The NDB scheme only requires notification for **eligible data breaches**, defined by two conditions both being true:

1. **Unauthorised access, unauthorised disclosure, or loss** of personal information held by the entity, AND
2. **Likely to result in serious harm** to one or more individuals to whom the information relates.

### 3a. Did personal information leak?

Yes if any of the following:
- Someone saw data that wasn't theirs (cross-unit, cross-role, kid → adult, etc.)
- Files (photos, exports) were accessible without proper auth
- An admin/instructor/parent account was used by someone other than the legitimate user
- Data left the system in any form (download, screenshot widely shared, etc.)

If no personal information was actually accessed or disclosed — just *potentially* could have been but logs prove it wasn't — note that fact and skip to section 5 (document only, no notification needed).

### 3b. Is serious harm likely?

"Likely" means **probable**, not just possible. "Serious harm" includes:

- **Physical** — e.g. someone with restraining order info exposed to abuser
- **Psychological / emotional** — distress, anxiety, fear from exposure of sensitive info (medical conditions, kids' info)
- **Financial** — fraud, identity theft (less likely for myBJJ since no payment info or government IDs are held)
- **Reputational** — embarrassment, social damage
- **Other** — discrimination, blackmail

For myBJJ, the highest-risk categories are:

- **Health information (medical_notes)** — sensitive by definition under the Privacy Act. Exposure likely qualifies as serious harm if names are attached.
- **Kids' data** — given the vulnerable nature of the subjects, exposure is almost certainly serious harm.
- **Identity + contact** (name, email, phone, date of birth) for many users — depends on context. Mass exposure = likely serious harm. Single user accidentally seeing one other's email = probably not.

### 3c. Eligibility decision

You have up to **30 days** to assess. Most assessments take minutes once logs are clear. Use this rule of thumb:

| Situation | Decision |
|---|---|
| Health information or kids' data leaked to unauthorised party | **Eligible** — notify |
| Many users' identity + contact info accessible to unauthorised party | **Eligible** — notify |
| One user briefly saw another's name (no sensitive info) | **Probably not eligible** — document only |
| Internal staff saw data they shouldn't see (RLS bug among instructors at same academy) | **Borderline** — lean toward notifying for transparency |
| Compromised account but no evidence data was accessed | **Borderline** — document, monitor, prepare to notify if evidence emerges |
| Unsure | **Notify**. Better to over-notify than under-notify. |

### 3d. Remediation that defuses the breach

If you can **take action that means serious harm is no longer likely** (e.g. the data was retrieved before anyone outside the academy saw it, the compromised account was caught before being used), the NDB scheme allows you to NOT notify. **Document the remediation thoroughly** in section 5.

---

## 4. Notify

If section 3 concludes the breach is eligible, you must notify:

1. **The Office of the Australian Information Commissioner (OAIC)**
2. **The individuals affected**

Both notifications must happen **as soon as practicable** after the eligibility determination. There is no fixed deadline ("X hours"), but delay is itself a breach. Australian Clinical Labs was fined AUD 1.6M specifically for delaying notification.

### 4a. Notify the OAIC

Use the official online form: **https://www.oaic.gov.au/privacy/notifiable-data-breaches/report-a-data-breach**

You'll need:

- Entity details (myBJJ, contact: info@mybjj.com.au, phone)
- Description of the breach (what happened, when discovered)
- Kinds of personal info involved
- Number of individuals affected (estimate is fine if exact is unknown)
- Likely consequences for affected individuals
- Steps taken / planned to contain
- Recommended steps for affected individuals to mitigate harm
- Contact for the OAIC follow-up

Save the submission confirmation. The OAIC may follow up by phone or email.

### 4b. Notify affected individuals

Send a separate email to each affected individual (or a group email if too many). The notification must contain:

- The identity and contact details of myBJJ
- Description of the breach
- Kinds of personal information involved
- Recommendations for steps they should take

**Email template to affected individuals:**

```
Subject: Important: a data incident affecting your myBJJ information

Dear [Name],

We are writing to let you know about a data incident at myBJJ that may have affected
information we hold about you.

What happened

[Describe in plain language. Example: "On [date], we discovered that due to a software
bug introduced on [earlier date], it was possible for adult members at your academy to
see [specific information] that should have been restricted. The bug has been fixed and
no one outside your academy was affected."]

What information was involved

[List specifically. Example: "Your full name, date of birth, and the medical notes you
entered in your profile."]

What we have done

[List remediation. Example: "We fixed the software bug on [date], audited access logs
to identify everyone affected, and have notified the Office of the Australian Information
Commissioner."]

What we recommend you do

[Concrete actions for them. For most myBJJ incidents this will be minimal — change
password if account compromised, contact the academy if concerned, etc.]

We are sorry this happened. If you have questions or would like more information,
please contact us at info@mybjj.com.au.

For information about your privacy rights or to make a complaint, you can contact the
Office of the Australian Information Commissioner at oaic.gov.au or 1300 363 992.

[Name / role]
myBJJ
```

For breaches involving children, send the email to the **parent's email**, not to anything kid-related.

---

## 5. Document

Maintain an incident log inside this section. Each entry:

```
### Incident YYYY-MM-DD — [short title]

- Time discovered:
- Time contained:
- Description:
- Personal info involved:
- Number of individuals affected:
- Eligibility decision: [eligible / not eligible / remediated]
- Reason for decision:
- OAIC notified: [yes / no, with date and reference number]
- Affected individuals notified: [yes / no, with date and method]
- Root cause:
- Preventive measures taken:
```

Keep this log even for non-eligible incidents. If OAIC ever investigates, this is your evidence of a working process.

### Incident log

*(none to date)*

---

## 6. Review (post-mortem)

Within 7 days of containing the incident, do a short post-mortem. Cover:

- **What happened** — narrative from detection through resolution
- **Why it happened** — root cause (technical, process, human)
- **Why it wasn't caught earlier** — gaps in monitoring, testing, RLS coverage
- **What changed** — the fix, plus structural changes to prevent recurrence (e.g. "added RLS smoke test before every migration")
- **Lessons** — for future development

Save the post-mortem in `~/mybjj-app/documentation/incidents/YYYY-MM-DD-short-title.md`.

---

## 7. Contact references (have these ready)

| Need | Where |
|---|---|
| OAIC breach report form | https://www.oaic.gov.au/privacy/notifiable-data-breaches/report-a-data-breach |
| OAIC phone | 1300 363 992 |
| OAIC mail | GPO Box 5288, Sydney NSW 2001 |
| Supabase support | https://supabase.com/dashboard/support |
| Supabase project | dcilltzgegqsrgatskhz (ap-southeast-2) |
| GitHub support | https://support.github.com |
| Repo | github.com/felipefaraone/mybjj-app |
| Academy contact | Mario Yokoyama — Neutral Bay — info@mybjj.com.au — (02) 8034 8157 |

---

## 8. Cheat sheet (the absolute minimum, when panicking)

1. **Note the time you became aware.**
2. **Contain** — stop the bleeding, do NOT delete logs.
3. **Snapshot the DB** for evidence.
4. **Pause and think:** is this an *eligible data breach* (personal info exposed + likely serious harm)?
5. If yes or unsure → **notify OAIC** via online form + **email affected individuals**.
6. **Log it** in section 5 of this document.
7. **Post-mortem** within 7 days.

If you are panicking, take a breath. The fact that you're following this document is itself most of what you need to be doing right.
