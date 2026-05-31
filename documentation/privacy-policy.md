# myBJJ Privacy Policy

**Last updated:** 31 May 2026
**Applies to:** myBJJ application at mybjj-app.com

This Privacy Policy explains how myBJJ ("we", "us", "our") collects, holds, uses, and discloses personal information when you use the myBJJ application at mybjj-app.com.

## Our role under the Privacy Act 1988

We comply with the Privacy Act 1988 (Cth) and the Australian Privacy Principles (APPs). Although the Privacy Act exempts most small businesses with an annual turnover below AUD $3 million, **we are nevertheless covered as a private-sector health service provider**. Brazilian Jiu-Jitsu training is an activity that assesses, maintains, and improves the physical health of our members, and we collect medical and emergency-contact information as part of running that service. This places us within the scope of the Privacy Act in line with the Office of the Australian Information Commissioner's (OAIC) published guidance for sporting clubs.

This policy is written to satisfy Australian Privacy Principle 1 ("Open and transparent management of personal information"), which requires us to publish a clearly expressed and up-to-date policy describing how we manage personal information.

## 1. The kinds of personal information we collect and hold

We collect only what is needed to run academy management.

### From adult students

- Identity: full name, date of birth, gender
- Contact: email address, phone number, social media handles (optional)
- Profile photo (optional; subject to academy approval before it is visible to others)
- Emergency contact: name and phone number (optional)
- **Health information** (sensitive information under the Privacy Act): medical notes such as allergies, injuries, or conditions relevant to training (optional)
- Physical attributes: weight and height (optional)
- **Training records**: belt rank, stripe and degree history, class attendance, instructor feedback, the date you started practicing BJJ

### From parents of child members

- Identity: full name
- Contact: email address, phone number
- Profile photo (optional; subject to academy approval)
- Notification preferences

### About children enrolled by their parents

- Identity: full name, date of birth, gender
- **Health information** (sensitive information): medical notes set by the parent (optional)
- Emergency contact details
- **Training records**: belt rank, stripe and degree history, class attendance, instructor feedback, the date they started practicing BJJ

### What we do not collect

- Photos of children (children's photo uploads are not enabled in the current version of the app)
- Payment information (the academy collects payment outside this app)
- Government identifiers (tax file number, Medicare number, driver's licence number)
- Biometric identifiers or templates
- Location data or browsing history outside the app
- Information for advertising, profiling, or marketing purposes (we do not run advertising in the app)

## 2. How we collect and hold personal information

**Collection.** We collect personal information directly from you when you sign up, log in, edit your profile, check in for a class, or upload a photo. For children, the parent provides the information through their own account.

**Holding.** Personal information is stored on Supabase, a managed PostgreSQL database and storage service. Our database, file storage, and authentication services are all hosted in the **Australian region** (Sydney, AWS ap-southeast-2). All connections to the app use TLS encryption.

Access to information inside the database is controlled by Row Level Security (RLS) policies enforced at the database layer — meaning that even if there is a bug in the application, members cannot see information they are not authorised to see. Passwords are never visible to us; they are hashed and stored by Supabase Auth.

Photos are stored in Supabase Storage with access governed by the same security rules.

For your convenience, the app uses a service worker to cache its interface on your device so it can load quickly and work briefly when you are offline. Cached information remains on your device until you clear it through your browser or operating system. The app does not use third-party analytics or tracking cookies.

## 3. The purposes for which we collect, hold, use and disclose personal information

We use your personal information to:

- Schedule classes and record attendance
- Track each member's belt journey and promotion eligibility
- Allow instructors to leave feedback and notes for students
- Show approved adult members who else trains at the academy (peer roster)
- Send in-app notifications about classes, promotions, feedback, and academy messages
- Maintain awareness of medical conditions relevant to training safety
- Show recent adult promotions to other adult members in the same academy (the Community Wall)

We do not use personal information to:

- Advertise to you or any third party
- Sell, rent, or trade your information
- Build profiles of you for purposes outside academy management
- Make automated decisions about you that have legal or similarly significant effects

### Sensitive information (health information)

We collect medical notes with your express consent. When you (or, for a child member, the child's parent) enter medical notes through the Edit Profile screen, you are providing consent for us to collect and use that information for the purposes described in this policy. You can clear or update medical notes at any time.

### Who can see your information inside the app

Visibility follows strict, role-based rules enforced by the database security policies, not only by the user interface:

- **Adult students** can see other adult students at the same academy as a peer roster (name, photo if approved, belt rank), and adult promotions on the Community Wall. They cannot see any information about children.
- **Parents** can see their own children's full profile, plus a non-identifying aggregate of the kids program (counts of children at each belt level — no names, no photos, no individual information about other children). Parents cannot see other adult members.
- **Instructors** can see all members at the academy where they teach, in order to do their job.
- **The academy owner** can see all members across academy locations they own.

**Other parents and other adults cannot see your child's individual information.** There is no direct messaging between adults and children in the app.

### Disclosure outside the academy

We disclose your personal information outside the academy and the app only:

- To Supabase, our database and storage provider, which holds the information in Australia on our behalf (see section 4)
- If required or authorised by Australian law or a court/tribunal order
- With your express consent

## 4. Cross-border disclosure (APP 8)

**Your information stays in Australia under normal operation.** Our database, file storage, authentication, and transactional email delivery are configured to keep data within Australia.

Supabase is operated by Supabase Inc., a company incorporated in the United States. Even though your data is physically held in the Australian region, the parent company could in principle be subject to United States legal process. We have not, to our knowledge, ever received such a request, and any future legal compulsion to disclose information would be honoured only to the minimum extent required by law.

We will update this policy if our hosting region or providers change.

## 5. Security of personal information (APP 11)

We take reasonable steps to protect your personal information from misuse, interference, loss, and unauthorised access, modification, or disclosure. These steps include:

- TLS encryption on all connections to the app
- Row Level Security policies enforced at the database layer (not only the user interface)
- Photo approval workflow: uploaded photos are not visible to other members until reviewed by the academy
- Sensitive information (medical notes, head instructor notes) restricted to the staff and individuals concerned
- Children's data restricted from all other parents and all other adults
- Regular encrypted database snapshots kept for backup and recovery
- Account-level controls for deletion and correction

In the event of a data breach that is likely to result in serious harm to affected individuals, we will notify those individuals and the OAIC in line with the Notifiable Data Breaches scheme (Part IIIC of the Privacy Act).

## 6. Child safety

We take particular care with information about children:

- Children do not have their own accounts. All access to a child's information goes through their parent's account.
- We do not collect or store photos of children in the current version of the app.
- Medical notes about a child can be entered only by their parent and are visible only to instructors, the academy owner, and that parent.
- The app does not facilitate direct messaging between adults and children.
- Other parents and other adults cannot see your child's individual information — only an aggregate count of how many children are at each belt level.
- Children's promotions do not appear on the Community Wall (only adult promotions do).
- Children's profiles are not visible in any adult peer roster.

Parents provide consent on behalf of children in line with current OAIC guidance, which presumes that individuals under 15 generally lack capacity to consent on their own. We will continue to align our practices with the Australian Government's Children's Online Privacy Code (anticipated to commence by 10 December 2026), including parental consent thresholds, age-appropriate notices, and privacy-protective defaults.

## 7. Access and correction (APPs 12 and 13)

You can:

- **Access** most of your personal information directly in the app's profile screens.
- **Request a complete export** of your information by emailing us (see Contact below).
- **Correct** your information in the app using Edit Profile, or by asking the academy.
- For a child, the parent has access and correction rights on the child's behalf.

We respond to written requests for access or correction **within 30 days**. We do not charge for the request itself. If substantial work is required to produce a complete export, we may charge a reasonable, non-excessive cost, which we will quote to you in advance.

If we refuse access or correction, we will tell you why in writing and explain how you can complain.

## 8. How to complain

If you believe we have mishandled your personal information, please contact us first (see Contact below). We will respond **within 30 days** and take reasonable steps to resolve the matter.

If you are not satisfied with our response, you can lodge a complaint with the Office of the Australian Information Commissioner:

- Website: oaic.gov.au
- Phone: 1300 363 992
- Mail: GPO Box 5288, Sydney NSW 2001

Since 10 June 2025, you also have a direct cause of action under the statutory tort for serious invasions of privacy (Schedule 2 of the Privacy Act), which you may pursue independently of any complaint to us or the OAIC.

## 9. How long we keep your information

We keep your personal information for as long as you are an active member of the academy, plus a reasonable period for record-keeping after you leave. We delete or de-identify personal information when it is no longer needed for any purpose for which it may be used or disclosed under the Privacy Act (APP 11.2), unless we are required to retain it by Australian law.

You may request deletion of your account at any time by contacting the academy. Some information may persist in encrypted database backups for up to six months after deletion before being permanently overwritten.

## 10. Changes to this policy

We may update this policy as the app evolves or as Australian privacy law changes. Material changes will be announced inside the app. The "last updated" date at the top of this page reflects the current version.

## 11. Contact

For any privacy-related question, access or correction request, or complaint, contact the academy:

**Neutral Bay**

- Mobile: 0406 456 766
- Studio: (02) 8034 8157
- Email: info@mybjj.com.au

For privacy-specific correspondence, email **info@mybjj.com.au** with the subject line **"Privacy"**. We will respond within 30 days.
