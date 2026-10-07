// supabase/functions/_shared/mia_emails.ts
//
// The MIA ("missing in action") emails, used by the mia-emails function:
//   M1 M2 M3 M4  to the member (adult) or the kid's guardians (kids)
//   T4           to the team (info@mybjj.com.au), with M4
//   R            "great to have you back"
//
// COPY: the head instructor's document "myBJJ MIA Member Email Sequence", word for
// word for ADULTS (subjects included; the document's curly apostrophes kept).
// The document has adult copy only. The KIDS copy below is ADAPTED: written to
// the parent about the child, every sentence keeping its meaning. Every adapted
// line is marked "ADAPTED" so it can be reviewed against the original next to it.
// Rendering goes through the shared layout (_shared/email_layout.ts); one primary
// button per member email (the document's), none in the team note.

import { renderLayout, type LayoutBlock } from "./email_layout.ts";
import { TIMETABLE_URL } from "./trial_emails.ts";
import { unitMapsUrl } from "./unit_address.ts";

export type MiaCode = "M1" | "M2" | "M3" | "M4" | "T4" | "R";
export type MiaStream = "adult" | "kids";
export const MIA_CODES: MiaCode[] = ["M1", "M2", "M3", "M4", "T4", "R"];
export const TEAM_ADDRESS = "info@mybjj.com.au";

// students.membership_level -> the label the app shows (index.html
// _MEMBERSHIP_LABELS). NULL is a regular full member ("Full member" in the app).
const MEMBERSHIP_LABELS: Record<string, string> = {
  visitor_other_gym: "Visitor (other myBJJ gym)",
  visitor_unaffiliated: "Visitor (non affiliated)",
  casual_dropin: "Casual Drop-In",
  casual_member: "Casual Member",
  plan_1_lesson: "One Lesson Membership",
  plan_2_lesson: "Two Lesson Membership",
  plan_unlimited: "Unlimited Membership",
};
export function membershipLabel(level: string | null): string {
  if (!level) return "Full member";
  return MEMBERSHIP_LABELS[level] || level;
}

const DOW = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
// 'YYYY-MM-DD' -> "Tuesday 1 Sep 2026"
export function fmtLongDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  return DOW[d.getUTCDay()] + " " + d.getUTCDate() + " " + MON[d.getUTCMonth()] + " " + d.getUTCFullYear();
}

type B =
  | { t: "p"; s: string }
  | { t: "btn"; label: string }               // every MIA button goes to the timetable
  | { t: "sign"; s: string[] }
  | { t: "details" }                          // T4: the member details
  | { t: "parents" }                           // T4 for a kid: the guardians
  | { t: "sent" };                            // T4: "Automated emails sent: …" (what the member actually got)
interface Tpl { subject: string; blocks: B[] }
const p = (s: string): B => ({ t: "p", s });
const btn = (label: string): B => ({ t: "btn", label });
const sign = (...s: string[]): B => ({ t: "sign", s });

// ================================ ADULT (the document) ================================
const ADULT: Record<MiaCode, Tpl> = {
  M1: { subject: "Haven’t seen you this week, {{first_name}}", blocks: [
    p("Hi {{first_name}},"),
    p("We haven’t seen you on the mats this week, so we just wanted to check in."),
    p("Hopefully everything’s going well and life has just been keeping you busy."),
    p("Whenever you’re ready, we’d love to see you back at training."),
    p("You can check the timetable below and find a class that works for you."),
    btn("VIEW TIMETABLE"),
    sign("See you on the mats,", "The myBJJ Team"),
  ] },
  M2: { subject: "Everything okay, {{first_name}}?", blocks: [
    p("Hi {{first_name}},"),
    p("It’s been a couple of weeks since we’ve seen you at myBJJ, so we wanted to check in."),
    p("Sometimes work gets busy, people go away, injuries happen, or training just gets pushed down the list for a while."),
    p("Whatever the reason, we hope everything’s okay."),
    p("If there’s something keeping you away from training, feel free to reply and let us know."),
    p("And if you’ve simply been meaning to get back in, there’s no need to wait for the perfect week."),
    p("Pick a class and come train."),
    btn("VIEW TIMETABLE"),
    p("We’d be happy to see you back."),
    sign("The myBJJ Team"),
  ] },
  M3: { subject: "Time to get back on the mats?", blocks: [
    p("Hi {{first_name}},"),
    p("It’s been a little while since your last class."),
    p("And we know what can happen."),
    p("You miss a week."),
    p("Then another week gets busy."),
    p("And suddenly getting back to training feels harder than it should."),
    p("The good news is you don’t need to get fit again before coming back."),
    p("You don’t need to remember everything."),
    p("And nobody expects you to pick up exactly where you left off."),
    p("Just come back in and train."),
    p("One class is all it takes to get moving again."),
    btn("FIND MY NEXT CLASS"),
    p("We’d love to see you back on the mats."),
    sign("The myBJJ Team"),
  ] },
  M4: { subject: "We’d really like to see you back, {{first_name}}", blocks: [
    p("Hi {{first_name}},"),
    p("It’s been about a month since we’ve seen you at training."),
    p("We wanted to reach out because we don’t want someone who was part of our training community to quietly disappear without checking that everything is okay."),
    p("If life has simply been busy, your next class is waiting whenever you’re ready."),
    p("If there’s something making it difficult to come back, whether that’s your schedule, an injury, motivation or something else, reply and let us know."),
    p("There may be something we can help with."),
    p("And if you’ve just been waiting for the right day to return, make it this week."),
    btn("VIEW TIMETABLE"),
    p("We hope to see you back soon."),
    sign("The myBJJ Team"),
  ] },
  T4: { subject: "MIA Member Follow-Up: {{first_name}} {{last_name}}", blocks: [
    p("Hi Team,"),
    p("{{first_name}} {{last_name}} has now gone 30 days without attending a class."),
    p("Member details:"),
    { t: "details" },
    { t: "sent" },                                                                    // was: They have now received the automated MIA follow-up emails at 7, 14, 21 and 30 days.
    p("A personal check-in from someone at the academy is now recommended."),
    p("This could be a short phone call, SMS or personal message to see how they’re going and whether there is anything preventing them from returning to training."),
  ] },
  R: { subject: "Great to have you back, {{first_name}} 🥋", blocks: [
    p("Hi {{first_name}},"),
    p("It was great to see you back on the mats."),
    p("Getting back into training after some time away can sometimes be the hardest class to make."),
    p("Now that you’ve done it, keep the momentum going."),
    p("You don’t need a perfect training schedule."),
    p("Just keep showing up when you can and build the habit again."),
    p("See you at the next one."),
    sign("The myBJJ Team"),
    btn("VIEW TIMETABLE"),
  ] },
};

// ================================ KIDS (ADAPTED) ================================
// To the parent, about the child. {{child_first_name}} = the kid's first name,
// {{parent_first_name}} = the guardian's first name ("there" when unknown).
// Each adapted line carries the original in its comment.
const KIDS: Record<MiaCode, Tpl> = {
  M1: { subject: "Haven’t seen {{child_first_name}} this week", blocks: [            // ADAPTED: Haven’t seen you this week, {{first_name}}
    p("Hi {{parent_first_name}},"),                                                    // ADAPTED: Hi {{first_name}},
    p("We haven’t seen {{child_first_name}} on the mats this week, so we just wanted to check in."), // ADAPTED: We haven’t seen you on the mats this week, …
    p("Hopefully everything’s going well and life has just been keeping your family busy."),        // ADAPTED: … keeping you busy.
    p("Whenever {{child_first_name}} is ready, we’d love to see them back at training."),           // ADAPTED: Whenever you’re ready, we’d love to see you back at training.
    p("You can check the timetable below and find a class that works for you."),
    btn("VIEW TIMETABLE"),
    sign("See you on the mats,", "The myBJJ Team"),
  ] },
  M2: { subject: "Everything okay with {{child_first_name}}?", blocks: [              // ADAPTED: Everything okay, {{first_name}}?
    p("Hi {{parent_first_name}},"),                                                    // ADAPTED
    p("It’s been a couple of weeks since we’ve seen {{child_first_name}} at myBJJ, so we wanted to check in."), // ADAPTED: … since we’ve seen you at myBJJ …
    p("Sometimes school gets busy, families go away, injuries happen, or training just gets pushed down the list for a while."), // ADAPTED: Sometimes work gets busy, people go away, …
    p("Whatever the reason, we hope everything’s okay."),
    p("If there’s something keeping {{child_first_name}} away from training, feel free to reply and let us know."), // ADAPTED: … keeping you away …
    p("And if you’ve simply been meaning to get {{child_first_name}} back in, there’s no need to wait for the perfect week."), // ADAPTED: … meaning to get back in …
    p("Pick a class and bring {{child_first_name}} in to train."),                     // ADAPTED: Pick a class and come train.
    btn("VIEW TIMETABLE"),
    p("We’d be happy to see {{child_first_name}} back."),                              // ADAPTED: We’d be happy to see you back.
    sign("The myBJJ Team"),
  ] },
  M3: { subject: "Time for {{child_first_name}} to get back on the mats?", blocks: [  // ADAPTED: Time to get back on the mats?
    p("Hi {{parent_first_name}},"),                                                    // ADAPTED
    p("It’s been a little while since {{child_first_name}}’s last class."),            // ADAPTED: … since your last class.
    p("And we know what can happen."),
    p("{{child_first_name}} misses a week."),                                          // ADAPTED: You miss a week.
    p("Then another week gets busy."),
    p("And suddenly getting back to training feels harder than it should."),
    p("The good news is {{child_first_name}} doesn’t need to get fit again before coming back."), // ADAPTED: … you don’t need to get fit …
    p("They don’t need to remember everything."),                                      // ADAPTED: You don’t need to remember everything.
    p("And nobody expects them to pick up exactly where they left off."),              // ADAPTED: … expects you to pick up exactly where you left off.
    p("Just bring them back in to train."),                                            // ADAPTED: Just come back in and train.
    p("One class is all it takes to get moving again."),
    btn("FIND THEIR NEXT CLASS"),                                                      // ADAPTED: FIND MY NEXT CLASS
    p("We’d love to see {{child_first_name}} back on the mats."),                      // ADAPTED: We’d love to see you back on the mats.
    sign("The myBJJ Team"),
  ] },
  M4: { subject: "We’d really like to see {{child_first_name}} back", blocks: [       // ADAPTED: We’d really like to see you back, {{first_name}}
    p("Hi {{parent_first_name}},"),                                                    // ADAPTED
    p("It’s been about a month since we’ve seen {{child_first_name}} at training."),   // ADAPTED: … seen you at training.
    p("We wanted to reach out because we don’t want someone who was part of our training community to quietly disappear without checking that everything is okay."),
    p("If life has simply been busy, {{child_first_name}}’s next class is waiting whenever you’re ready."), // ADAPTED: … your next class is waiting …
    p("If there’s something making it difficult for {{child_first_name}} to come back, whether that’s your schedule, an injury, motivation or something else, reply and let us know."), // ADAPTED: … difficult to come back …
    p("There may be something we can help with."),
    p("And if you’ve just been waiting for the right day for {{child_first_name}} to return, make it this week."), // ADAPTED: … the right day to return …
    btn("VIEW TIMETABLE"),
    p("We hope to see {{child_first_name}} back soon."),                               // ADAPTED: We hope to see you back soon.
    sign("The myBJJ Team"),
  ] },
  T4: { subject: "MIA Member Follow-Up: {{first_name}} {{last_name}}", blocks: [
    p("Hi Team,"),
    p("{{first_name}} {{last_name}} has now gone 30 days without attending a class."),
    p("Member details:"),
    { t: "details" },
    { t: "parents" },                                                                 // ADDED for kids: the guardians, with email and phone when known
    { t: "sent" },                                                                    // was: They have now received the automated MIA follow-up emails at 7, 14, 21 and 30 days.
    p("A personal check-in from someone at the academy is now recommended."),
    p("This could be a short phone call, SMS or personal message to see how they’re going and whether there is anything preventing them from returning to training."),
  ] },
  R: { subject: "Great to have {{child_first_name}} back 🥋", blocks: [               // ADAPTED: Great to have you back, {{first_name}} 🥋
    p("Hi {{parent_first_name}},"),                                                    // ADAPTED
    p("It was great to see {{child_first_name}} back on the mats."),                   // ADAPTED: … to see you back on the mats.
    p("Getting back into training after some time away can sometimes be the hardest class to make."),
    p("Now that {{child_first_name}} has done it, keep the momentum going."),          // ADAPTED: Now that you’ve done it, …
    p("They don’t need a perfect training schedule."),                                 // ADAPTED: You don’t need a perfect training schedule.
    p("Just keep bringing them in when you can and build the habit again."),           // ADAPTED: Just keep showing up when you can …
    p("See you at the next one."),
    sign("The myBJJ Team"),
    btn("VIEW TIMETABLE"),
  ] },
};

// ---- rendering ----------------------------------------------------------------------
export interface MiaParent { name: string | null; email: string | null; phone: string | null }
// What the member actually got this episode, for the T4 line.
export interface MiaSent { codes: string[]; reason: string | null }   // reason: only used when codes is empty

const DAYS_OF: Record<string, number> = { M1: 7, M2: 14, M3: 21, M4: 30 };
// ["M2","M3","M4"] -> "14, 21 and 30 days"; [] -> "none (<reason>)"
export function automatedSentLine(x: MiaSent | null): string {
  const days = (x?.codes || []).filter((c) => c in DAYS_OF).map((c) => DAYS_OF[c]).sort((a, b) => a - b)
    .filter((d, i, arr) => arr.indexOf(d) === i);
  if (!days.length) return `Automated emails sent: none (${(x?.reason || "started after launch").trim()}).`;
  const list = days.length === 1 ? String(days[0]) : days.slice(0, -1).join(", ") + " and " + days[days.length - 1];
  return `Automated emails sent: ${list} days.`;
}
// SQL member_reach (+ whether this run's M4 failed) -> the reason in brackets.
export function noneReason(memberReach: string | null, m4Failed: boolean): string {
  if (memberReach === "opted_out") return "opted out";
  if (memberReach === "no_address") return "no email address on file";
  if (m4Failed) return "the 30-day email failed to send and will be retried";
  return "started after launch";
}
export interface MiaVars {
  firstName: string;            // the student's
  lastName: string | null;
  recipientName: string | null; // the guardian's (kids) — first word is used
  location: string;             // academy name
  addressLine: string | null;   // unitAddressLine(units.address)
  unitPhone: string | null;
  lastClassDate: string;        // 'YYYY-MM-DD'
  daysAbsent: number;
  membershipLevel: string | null;
  parents: MiaParent[] | null;  // T4 for a kid
  automated: MiaSent | null;    // T4: what the member actually got
  unsubscribeUrl: string | null; // member emails only
}

export function renderMiaEmail(code: MiaCode, stream: MiaStream, v: MiaVars):
  { subject: string; html: string; text: string } {
  const tpl = (stream === "kids" ? KIDS : ADULT)[code];
  const first = (v.firstName || "").trim();
  const vars: Record<string, string> = {
    first_name: first || "there",
    child_first_name: first || "your child",
    parent_first_name: (v.recipientName || "").trim().split(/\s+/)[0] || "there",
    last_name: (v.lastName || "").trim(),
  };
  const fill = (s: string) =>
    s.replace(/\{\{(\w+)\}\}/g, (_, k) => vars[k] ?? "").replace(/ +$/, "").replace(/ {2,}/g, " ");
  const blocks: LayoutBlock[] = [];
  const text: string[] = [];
  for (const b of tpl.blocks) {
    if (b.t === "p") { blocks.push({ t: "p", parts: [fill(b.s)] }); text.push(fill(b.s), ""); }
    else if (b.t === "btn") {
      // One button per member email in the document, so it is the primary.
      blocks.push({ t: "button", label: b.label, href: TIMETABLE_URL, primary: true });
      text.push(`${b.label}: ${TIMETABLE_URL}`, "");
    }
    else if (b.t === "sign") { blocks.push({ t: "sign", lines: b.s }); text.push(...b.s, ""); }
    else if (b.t === "details") {
      const rows: [string, string][] = [
        ["Name", [first, (v.lastName || "").trim()].filter(Boolean).join(" ")],
        ["Academy", v.location || ""],
        ["Last class", fmtLongDate(v.lastClassDate)],
        ["Days since last class", String(v.daysAbsent)],
        ["Membership status", membershipLabel(v.membershipLevel)],   // the real value, never a fixed "Active"
      ];
      blocks.push({ t: "details", rows: rows.map(([label, value]) => ({ label, value })) });
      text.push(...rows.map(([k, val]) => `${k}: ${val}`), "");
    }
    else if (b.t === "sent") {
      const line = automatedSentLine(v.automated);
      blocks.push({ t: "p", parts: [line] }); text.push(line, "");
    }
    else if (b.t === "parents") {
      const ps = (v.parents || []).filter((x) => x && (x.name || x.email || x.phone));
      if (!ps.length) continue;
      const line = (x: MiaParent) => [x.name, x.email, x.phone].filter(Boolean).join(" · ");
      blocks.push({ t: "p", parts: [], lines: [["Parents / guardians:"], ...ps.map((x) => [line(x)])] });
      text.push("Parents / guardians:", ...ps.map(line), "");
    }
  }
  const team = code === "T4";
  const why = team
    ? "Sent automatically by the myBJJ MIA follow-up."
    : stream === "kids"
    ? "You’re getting this because a child you look after trains at myBJJ."
    : "You’re getting this because you train at myBJJ.";
  const unsub = team ? "" : (v.unsubscribeUrl || "");
  text.push(why, ...(unsub ? [`Don't want these emails? Unsubscribe: ${unsub}`] : []));
  const subject = fill(tpl.subject).replace(/[\r\n]+/g, " ");
  const html = renderLayout({
    subject,
    blocks,
    footer: {
      academy: v.location || null,
      address: v.addressLine,
      mapsUrl: unitMapsUrl(v.addressLine),
      phone: v.unitPhone,
      why,
      unsubscribeUrl: unsub || null,
    },
  });
  return { subject, html, text: text.join("\n") };
}
