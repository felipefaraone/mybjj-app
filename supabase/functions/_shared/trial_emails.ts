// supabase/functions/_shared/trial_emails.ts
//
// The trial email sequence, ONE copy, used by:
//   trial-booking  -> email 1 (sent at booking time)
//   trial-emails   -> emails 2, 3A-6A, 3B-5B (sent when due)
//
// COPY: the head instructor's document "Trial Student Email Automation"
// (adult stream 1A, kids stream 1B), word for word, subject lines included. Lines
// marked KEPT FROM THE PREVIOUS CONFIRMATION are things the old trial-booking
// confirmation did that the document doesn't, kept on purpose (see the report).
//
// Every interpolated value is escaped. Buttons:
//   directions  -> the Google Maps link the old confirmation built (hidden when
//                  the academy has no address)
//   book        -> https://mybjj-app.com/trial.html?unit=<legacy id>
//   timetable   -> TIMETABLE_URL
//   membership  -> MEMBERSHIP_URL  (the About page for now; label MEMBERSHIP_BUTTON_LABEL)

import { escHtml, renderLayout, type LayoutBlock } from "./email_layout.ts";
import { unitMapsUrl } from "./unit_address.ts";
export { escHtml };

// ---- links ------------------------------------------------------------------------
// Every URL is ONE complete literal. Never build one from an origin plus a
// page path string: the Edge Function bundler reads a literal that looks like
// an absolute path as a file to include, and the deploy fails
// ("failed to read file: open /unsubscribe.html").
export const TIMETABLE_URL = "https://mybjj.com.au/my-schedule/";
// The site has no membership page yet, so this is the About page, and the buttons
// that point here use MEMBERSHIP_BUTTON_LABEL (see below), not membership wording.
export const MEMBERSHIP_URL = "https://mybjj.com.au/aboutus/";
// The label of every button that points at MEMBERSHIP_URL (the document's "VIEW
// MEMBERSHIP OPTIONS", "VIEW KIDS MEMBERSHIP OPTIONS" and "JOIN myBJJ"). Switch it
// back when the new site has a membership page.
export const MEMBERSHIP_BUTTON_LABEL = "LEARN MORE ABOUT myBJJ";
export const TRIAL_PAGE = "https://mybjj-app.com/trial.html";
export const UNSUB_PAGE = "https://mybjj-app.com/unsubscribe.html";
// Sender for every trial email (email 1 from trial-booking included).
export const TRIAL_FROM = "MyBJJ <noreply@mybjj-app.com>";
export const TRIAL_REPLY_TO = "info@mybjj.com.au";


// ---- formatting (same output as trial-booking's own helpers) ----------------------
const DOW = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
// 'YYYY-MM-DD' -> "Wednesday 15 Jul"
export function fmtDayDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  return DOW[d.getUTCDay()] + " " + d.getUTCDate() + " " + MON[d.getUTCMonth()];
}
// 'HH:MM' -> "6:00 PM"
export function fmt12(t: string): string {
  const [h, m] = String(t).split(":").map(Number);
  const ap = h < 12 ? "AM" : "PM";
  let hr = h % 12; if (hr === 0) hr = 12;
  return hr + ":" + String(m).padStart(2, "0") + " " + ap;
}
// Mirrors trial-booking's classLabel (public_timetable's labels + the page's two
// audience overrides), so follow-ups name the class the person actually booked.
export function classLabel(type: string, audience: string): string {
  if (type === "jmma") return "Kids MMA";
  if (type === "alev" && audience === "Kids") return "Teens BJJ";
  const base: Record<string, string> = {
    nogi: "No-Gi", gi: "Gi", alev: "All Levels", beg: "Beginners", adv: "Advanced",
    fund: "Fundamentals", mma: "MMA", jmma: "Junior MMA", jun: "Juniors",
    mini: "Mini Kids", omat: "Open Mat",
  };
  return base[type] || (type ? type.charAt(0).toUpperCase() + type.slice(1) : "Class");
}
// The Maps link for the unit's address line (_shared/unit_address.ts).
export const mapsUrlFor = unitMapsUrl;

// ---- unsubscribe (same signing rule as engagement-emails / email-unsubscribe) ------
async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
export async function trialUnsubUrl(secret: string | undefined | null, email: string): Promise<string | null> {
  if (!secret || !email) return null;
  const e = String(email).trim().toLowerCase();
  const q = new URLSearchParams({
    email: e, kind: "trial",
    sig: await hmacHex(secret, e + "|trial"),
    sig_all: await hmacHex(secret, e + "|all"),
  });
  return `${UNSUB_PAGE}?${q.toString()}`;
}

// ---- the emails ---------------------------------------------------------------------
export type Code = "1" | "2" | "3A" | "4A" | "5A" | "6A" | "3B" | "4B" | "5B";
export type Stream = "adult" | "kids";
export const CODES: Code[] = ["1", "2", "3A", "4A", "5A", "6A", "3B", "4B", "5B"];

type Href = "directions" | "book" | "timetable" | "membership";
type Block =
  | { t: "p"; s: string }
  | { t: "h"; s: string }
  | { t: "details1" }                 // email 1: Academy / Class / Date / Time
  | { t: "details2" }                 // email 2: class / date at time / location
  | { t: "waiver" }                  // email 1: the health check CTA, exactly as before
  | { t: "btn"; label: string; href: Href }
  | { t: "sign"; s: string[] }
  | { t: "kept_email1_tail" };       // email 1: kept from the previous confirmation

interface Tpl { subject: string; blocks: Block[] }
const p = (s: string): Block => ({ t: "p", s });
const h = (s: string): Block => ({ t: "h", s });
const btn = (label: string, href: Href): Block => ({ t: "btn", label, href });
const sign = (...s: string[]): Block => ({ t: "sign", s });

// ------------------------------- STREAM 1A: ADULT -------------------------------
const ADULT: Record<Code, Tpl> = {
  "1": { subject: "Your free trial at myBJJ is booked 🥋", blocks: [
    p("Hi {{first_name}},"),
    p("You're booked in for your free trial at myBJJ. We're looking forward to having you on the mats."),
    h("Your trial"), { t: "details1" }, { t: "waiver" },
    p("If you've never done Brazilian Jiu-Jitsu before, that's exactly what the trial is for."),
    p("You don't need any martial arts experience and you don't need to get fit before you start. We'll show you what to do from the moment you arrive."),
    h("What should I wear?"),
    p("Comfortable training clothes are fine for your first session. A T-shirt with shorts or athletic pants is perfect."),
    p("If you already own a BJJ gi, you're welcome to bring it, but there's no need to buy equipment before your trial."),
    p("No jewellery, please."), // KEPT FROM THE PREVIOUS CONFIRMATION
    p("Bring some water and try to arrive 10 to 15 minutes before class so we can show you around and get you settled in."),
    p("If you have any questions beforehand, just reply to this email."),
    sign("See you soon,", "The myBJJ Team"),
    btn("VIEW LOCATION & DIRECTIONS", "directions"),
    { t: "kept_email1_tail" },
  ] },
  "2": { subject: "See you tomorrow at myBJJ, {{first_name}}", blocks: [
    p("Hi {{first_name}},"),
    p("Just a quick reminder that your free Brazilian Jiu-Jitsu trial is tomorrow."),
    { t: "details2" },
    p("Try to arrive 10 to 15 minutes before class."),
    p("Bring some water, wear comfortable training clothes and we'll take care of everything else."),
    p("If you're feeling a little nervous about walking into a BJJ academy for the first time, that's completely normal."),
    p("Everyone on our mats had a first class once."),
    p("Tomorrow is yours."),
    sign("See you then,", "The myBJJ Team"),
    btn("VIEW LOCATION & DIRECTIONS", "directions"),
  ] },
  "3A": { subject: "Great having you on the mats, {{first_name}}", blocks: [
    p("Hi {{first_name}},"),
    p("Thanks for coming in and training with us at myBJJ."),
    p("Your first Brazilian Jiu-Jitsu class can throw a lot at you, so if you walked away thinking, \"I'm not sure I remember any of that,\" you're in good company."),
    p("Nobody is expected to understand BJJ after one class."),
    p("The important part is getting back on the mats."),
    p("After a few sessions, you'll start recognising the positions, movements and techniques. Things that felt completely unfamiliar during your first class gradually begin making sense."),
    p("We'd love to have you back."),
    btn("VIEW THE TIMETABLE", "timetable"),
    p("If you have any questions about training or getting started, simply reply to this email."),
    sign("See you on the mats,", "The myBJJ Team"),
  ] },
  "4A": { subject: "What happens after your first BJJ class?", blocks: [
    p("Hi {{first_name}},"),
    p("So you've completed your first BJJ class."),
    p("What happens next?"),
    p("At first, Brazilian Jiu-Jitsu can feel like learning a completely new language."),
    p("Then you start recognising positions."),
    p("Movements begin feeling more natural."),
    p("Techniques start connecting together."),
    p("You get to know the people you're training with."),
    p("And gradually you stop feeling like the new person in the room."),
    p("You don't need to train every day to improve."),
    p("For most beginners, simply getting onto the mats consistently each week makes an enormous difference."),
    p("Fitness improves through training."),
    p("Confidence grows through training."),
    p("And BJJ starts making sense through training."),
    p("You don't have to be ready before you continue."),
    p("Continuing is how you get ready."),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    sign("Hope to see you back soon,", "The myBJJ Team"),
  ] },
  "5A": { subject: "Ready to keep training, {{first_name}}?", blocks: [
    p("Hi {{first_name}},"),
    p("You've already done something a lot of people spend months thinking about."),
    p("You walked into a Brazilian Jiu-Jitsu academy and gave it a go."),
    p("If you enjoyed your trial, the next step is simple."),
    p("Keep showing up."),
    p("As a myBJJ member, you'll continue learning alongside your instructors and training partners while developing your technique, fitness and confidence over time."),
    p("You don't need to know enough yet."),
    p("You don't need to be fitter first."),
    p("And you don't need to wait until you feel like a \"BJJ person\"."),
    p("That's what the journey is for."),
    p("If you'd like to continue, you can get started below."),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    p("Not sure which membership is right for you? Reply to this email and we'll help."),
    sign("See you on the mats,", "The myBJJ Team"),
  ] },
  "6A": { subject: "Can we help with anything, {{first_name}}?", blocks: [
    p("Hi {{first_name}},"),
    p("You tried Brazilian Jiu-Jitsu with us recently, but we haven't seen you take the next step yet."),
    p("Rather than sending you another email telling you to join, we thought we'd ask:"),
    p("Is there anything stopping you from continuing?"),
    p("Maybe you're trying to make training work around your schedule."),
    p("Maybe you have a question about membership."),
    p("Maybe you're not sure how often you need to train."),
    p("Maybe you enjoyed it but you're still deciding whether BJJ is right for you."),
    p("Or maybe life just got busy."),
    p("Whatever it is, reply and let us know."),
    p("There's no pressure. If there's something we can help with, we will."),
    p("And if you're ready to get back on the mats:"),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    sign("Hope to see you again,", "The myBJJ Team"),
  ] },
  "3B": { subject: "We missed you at myBJJ, {{first_name}}", blocks: [
    p("Hi {{first_name}},"),
    p("It looks like you weren't able to make it to your free trial at myBJJ."),
    p("If something came up, no problem."),
    p("You're still very welcome to come in and give Brazilian Jiu-Jitsu a try."),
    p("Choose another class that suits you and we'll take care of the rest."),
    btn("REBOOK MY FREE TRIAL", "book"),
    p("If you're unsure which class to choose, simply reply to this email and we'll help."),
    sign("Hope to see you on the mats soon,", "The myBJJ Team"),
  ] },
  "4B": { subject: "Still thinking about trying BJJ?", blocks: [
    p("Hi {{first_name}},"),
    p("There's usually a reason people keep putting off their first Brazilian Jiu-Jitsu class."),
    p("Sometimes it's:"),
    p("\"I need to get fitter first.\""),
    p("You don't. Training is what gets you fitter."),
    p("\"I've never done martial arts.\""),
    p("That's fine. Beginners aren't expected to know anything."),
    p("\"Everyone there will be better than me.\""),
    p("They probably will be. They were beginners once too."),
    p("\"I'll look stupid because I don't know what I'm doing.\""),
    p("You won't be expected to know what you're doing. That's why we have instructors."),
    p("Almost everyone feels some nerves before their first class."),
    p("The hardest part is usually walking through the door."),
    p("After that, we'll look after you."),
    btn("BOOK MY FREE TRIAL", "book"),
    sign("See you soon,", "The myBJJ Team"),
  ] },
  "5B": { subject: "Your invitation to try myBJJ is still open", blocks: [
    p("Hi {{first_name}},"),
    p("We wanted to send you one last invitation to come in and try Brazilian Jiu-Jitsu with us."),
    p("If you'd still like to give BJJ a go, your free trial is waiting for you."),
    p("No experience required."),
    p("No need to get fit first."),
    p("No pressure to know what you're doing."),
    p("Just choose a class, come down and experience it for yourself."),
    btn("BOOK MY FREE TRIAL", "book"),
    p("If now isn't the right time, that's okay too."),
    p("And if there's something you'd like to know before deciding, reply to this email and ask us."),
    p("We'd be happy to help."),
    sign("The myBJJ Team"),
  ] },
};

// -------------------------------- STREAM 1B: KIDS --------------------------------
// Written to the parent; {{child_first_name}} is the first word of kid_name.
const KIDS: Record<Code, Tpl> = {
  "1": { subject: "{{child_first_name}}'s free trial at myBJJ is booked 🥋", blocks: [
    p("Hi {{parent_first_name}},"),
    p("Thanks for booking a free trial for {{child_first_name}} at myBJJ."),
    p("We're looking forward to welcoming you both to the academy."),
    h("Trial details"), { t: "details1" }, { t: "waiver" },
    p("There's no previous martial arts experience required."),
    p("Our instructors will explain everything and help {{child_first_name}} settle into the class."),
    h("What should they wear?"),
    p("Comfortable sports clothes are fine for the trial."),
    p("A T-shirt with shorts or athletic pants works well. There's no need to purchase a BJJ uniform before they've tried a class."),
    p("No jewellery, please."), // KEPT FROM THE PREVIOUS CONFIRMATION
    p("Bring some water and try to arrive around 10 to 15 minutes before class so there's time to meet the team and get comfortable before training begins."),
    p("Kids respond to their first class in different ways."),
    p("Some can't wait to jump straight in."),
    p("Others prefer to watch for a moment and work out what's happening first."),
    p("Both are completely normal."),
    p("Our team will help {{child_first_name}} get settled."),
    p("If you have any questions before the class, just reply to this email."),
    sign("See you soon,", "The myBJJ Team"),
    btn("VIEW LOCATION & DIRECTIONS", "directions"),
    { t: "kept_email1_tail" },
  ] },
  "2": { subject: "We'll see {{child_first_name}} tomorrow 🥋", blocks: [
    p("Hi {{parent_first_name}},"),
    p("Just a quick reminder that {{child_first_name}}'s free trial at myBJJ is tomorrow."),
    { t: "details2" },
    p("Try to arrive 10 to 15 minutes before class so there's plenty of time to settle in."),
    p("They can wear comfortable sports clothes and bring some water."),
    p("If {{child_first_name}} is a little nervous, that's absolutely fine."),
    p("Starting something new can be a big deal for kids, and we won't expect them to walk through the door already knowing what to do."),
    p("Our instructors will help from there."),
    p("We're looking forward to meeting you both."),
    sign("The myBJJ Team"),
    btn("VIEW LOCATION & DIRECTIONS", "directions"),
  ] },
  "3A": { subject: "How did {{child_first_name}} enjoy their first class?", blocks: [
    p("Hi {{parent_first_name}},"),
    p("Thanks for bringing {{child_first_name}} in for their first class at myBJJ."),
    p("We hope they enjoyed getting onto the mats and experiencing Brazilian Jiu-Jitsu."),
    p("The first class is really just an introduction."),
    p("Everything is new, including the academy, instructors, other students, movements and techniques."),
    p("It normally takes a few classes before children begin feeling completely comfortable with how everything works."),
    p("That's why we'd love to see {{child_first_name}} back on the mats."),
    btn("VIEW THE KIDS TIMETABLE", "timetable"),
    p("And we'd genuinely love to know how they felt about the class."),
    p("If you have any questions or there's anything {{child_first_name}} was unsure about, simply reply to this email."),
    sign("See you soon,", "The myBJJ Team"),
  ] },
  "4A": { subject: "What kids start gaining from regular BJJ training", blocks: [
    p("Hi {{parent_first_name}},"),
    p("One class gives {{child_first_name}} a taste of Brazilian Jiu-Jitsu."),
    p("The real benefits start appearing through regular training."),
    p("As children become more comfortable on the mats, they're learning much more than individual BJJ techniques."),
    p("They're learning to listen to instructions."),
    p("Solve problems."),
    p("Work with different training partners."),
    p("Deal with challenges."),
    p("Keep trying when something doesn't work immediately."),
    p("And become more confident in an environment that initially felt unfamiliar."),
    p("Of course, they're also learning Brazilian Jiu-Jitsu."),
    p("Progress doesn't happen overnight, and every child develops differently."),
    p("The important part is giving them the opportunity to keep showing up, learning and improving."),
    p("If {{child_first_name}} enjoyed the first session, we'd love to help them continue."),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    sign("See you at the academy,", "The myBJJ Team"),
  ] },
  "5A": { subject: "Would {{child_first_name}} like to keep training?", blocks: [
    p("Hi {{parent_first_name}},"),
    p("{{child_first_name}} has already taken the first step by coming in and trying Brazilian Jiu-Jitsu."),
    p("If they enjoyed the experience, we'd love to welcome them into the myBJJ team."),
    p("Joining isn't about already being good at BJJ."),
    p("That's what classes are for."),
    p("Children learn gradually through regular training with their instructors and teammates."),
    p("They develop their skills over time, become more comfortable on the mats and get to experience the satisfaction that comes from learning something that was difficult before."),
    p("If you'd like {{child_first_name}} to continue, you can see the next steps below."),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    p("If you'd like to discuss which option is right for your family, simply reply to this email."),
    p("We're happy to help."),
    sign("The myBJJ Team"),
  ] },
  "6A": { subject: "Any questions about BJJ for {{child_first_name}}?", blocks: [
    p("Hi {{parent_first_name}},"),
    p("You brought {{child_first_name}} in to try Brazilian Jiu-Jitsu recently, but we haven't seen them continue yet."),
    p("So we wanted to check whether there's anything we can help with."),
    p("Perhaps you're trying to fit classes around school and other activities."),
    p("Maybe you'd like to understand the membership options."),
    p("Maybe {{child_first_name}} enjoyed the class but felt a little nervous."),
    p("Or you might simply still be deciding whether BJJ is right for them."),
    p("Whatever the reason, you're welcome to reply to this email."),
    p("If there's a question we can answer or something you're unsure about, we'd be happy to help."),
    p("And if you're ready for {{child_first_name}} to continue:"),
    btn(MEMBERSHIP_BUTTON_LABEL, "membership"),
    sign("Hope to see you both again soon,", "The myBJJ Team"),
  ] },
  "3B": { subject: "We missed {{child_first_name}} at myBJJ", blocks: [
    p("Hi {{parent_first_name}},"),
    p("It looks like {{child_first_name}} wasn't able to make it to their trial class."),
    p("If something came up, no problem at all."),
    p("Their free trial is still available and we'd love to have them come in another day."),
    p("You can choose another suitable class below."),
    btn("REBOOK THEIR FREE TRIAL", "book"),
    p("If you're unsure which class is best for {{child_first_name}}, just reply to this email and we'll help."),
    sign("Hope to meet you both soon,", "The myBJJ Team"),
  ] },
  "4B": { subject: "Is {{child_first_name}} nervous about trying BJJ?", blocks: [
    p("Hi {{parent_first_name}},"),
    p("If {{child_first_name}} was a little unsure about coming to their first Brazilian Jiu-Jitsu class, that's very normal."),
    p("Walking into a room full of new people and trying something completely unfamiliar can be intimidating for a child."),
    p("Some kids run straight onto the mats."),
    p("Others need a little more time."),
    p("We don't expect a child attending their first session to already know the rules, techniques or other students."),
    p("That's our job."),
    p("Our instructors will explain what to do, introduce them to the class and help them become comfortable with the environment."),
    p("The first goal isn't for {{child_first_name}} to be good at BJJ."),
    p("It's simply to give them the opportunity to try it."),
    btn("BOOK ANOTHER FREE TRIAL", "book"),
    p("If there's something you're concerned about before bringing them in, reply to this email and let us know."),
    sign("The myBJJ Team"),
  ] },
  "5B": { subject: "{{child_first_name}}'s free trial is still waiting", blocks: [
    p("Hi {{parent_first_name}},"),
    p("We wanted to send you one final invitation to bring {{child_first_name}} in to try Brazilian Jiu-Jitsu at myBJJ."),
    p("There's no experience required and no expectation that they'll already know what to do."),
    p("Their first class is simply an opportunity to get onto the mats, meet our team and see what BJJ is like."),
    p("If you'd still like them to give it a try:"),
    btn("BOOK THEIR FREE TRIAL", "book"),
    p("If now isn't the right time, that's completely fine."),
    p("And if there's anything you'd like to ask before deciding, just reply to this email."),
    p("We hope we get the chance to meet you both."),
    sign("The myBJJ Team"),
  ] },
};

// ---- rendering ----------------------------------------------------------------------
export interface TrialEmailVars {
  firstName: string;            // the booker (the parent, for kids)
  childFirstName: string;       // kids only; "" for adults
  location: string;             // academy name, e.g. "Neutral Bay"
  className: string | null;     // null on the "none of these times work" path (email 1 only)
  trialDate: string | null;     // "Wednesday 15 Jul"
  trialTime: string | null;     // "6:00 PM"
  addressLine: string | null;   // unitAddressLine(units.address); null when the academy has none
  unitLegacyId: string | null;  // for the book buttons
  unitPhone: string | null;     // email 1 sign-off line (kept from the old confirmation)
  waiverLink: string | null;    // email 1 only
  unsubscribeUrl: string | null;
}

export function renderTrialEmail(code: Code, stream: Stream, v: TrialEmailVars):
  { subject: string; html: string; text: string } {
  const tpl = (stream === "kids" ? KIDS : ADULT)[code];
  const vars: Record<string, string> = {
    first_name: v.firstName || "there",
    parent_first_name: v.firstName || "there",
    child_first_name: v.childFirstName || "your child",
    location: v.location || "myBJJ",
    class_name: v.className || "",
    trial_date: v.trialDate || "",
    trial_time: v.trialTime || "",
  };
  // Plain text with the values filled in; the layout escapes everything.
  const fill = (s: string) =>
    s.split(/(\{\{\w+\}\})/).map((part) => {
      const m = /^\{\{(\w+)\}\}$/.exec(part);
      return m ? (vars[m[1]] ?? "") : part;
    }).join("");
  const maps = mapsUrlFor(v.addressLine);
  const hrefOf = (k: Href): string | null =>
    k === "directions" ? maps
      : k === "book" ? TRIAL_PAGE + (v.unitLegacyId ? "?unit=" + encodeURIComponent(v.unitLegacyId) : "")
      : k === "timetable" ? TIMETABLE_URL
      : MEMBERSHIP_URL;
  const trialUrl = TRIAL_PAGE;

  // HTML goes through the shared layout (_shared/email_layout.ts); the plain text
  // is built here, block for block, exactly as before.
  // Buttons: in email 1 the health check is the primary and every other button is
  // secondary; in every other email the document's one button is the primary.
  const blocks: LayoutBlock[] = [];
  const textParts: string[] = [];
  const hasWaiver = tpl.blocks.some((b) => b.t === "waiver") && !!v.waiverLink;
  for (const b of tpl.blocks) {
    if (b.t === "p") { blocks.push({ t: "p", parts: [fill(b.s)] }); textParts.push(fill(b.s), ""); }
    else if (b.t === "h") { blocks.push({ t: "h", text: fill(b.s) }); textParts.push(fill(b.s)); }
    else if (b.t === "details1") {
      const rows: [string, string][] = [["Academy", vars.location]];
      if (v.className && v.trialDate && v.trialTime) {
        rows.push(["Class", v.className], ["Date", v.trialDate], ["Time", v.trialTime]);
      }
      // KEPT FROM THE PREVIOUS CONFIRMATION: the address as a Maps link, and the
      // "we'll confirm your time" line on the no-class path.
      blocks.push({
        t: "details",
        rows: [
          ...rows.map(([k, val]) => ({ label: k, value: val })),
          ...(v.addressLine ? [{ label: "Address", value: maps ? { text: v.addressLine, href: maps } : v.addressLine }] : []),
        ],
        note: v.className ? undefined : "We'll confirm your class time with you shortly.",
      });
      textParts.push(...rows.map(([k, val]) => `${k}: ${val}`));
      if (v.addressLine) textParts.push(`Address: ${v.addressLine}`, ...(maps ? [maps] : []));
      if (!v.className) textParts.push("We'll confirm your class time with you shortly.");
      textParts.push("");
    }
    else if (b.t === "details2") {
      const lines = [vars.class_name, `${vars.trial_date} at ${vars.trial_time}`, vars.location];
      blocks.push({ t: "details", rows: lines.map((l, i) => ({ value: l, strong: i === 1 })) });
      textParts.push(...lines, "");
    }
    else if (b.t === "waiver") {
      // The health check: the primary button of email 1, with its line under it.
      if (v.waiverLink) {
        blocks.push({ t: "button", label: "Complete your health check", href: v.waiverLink, primary: true,
          note: "It takes about three minutes, and it must be done before you train." });
        textParts.push("Complete your health check — it takes about three minutes, and it must be done before you train:", v.waiverLink, "");
      }
    }
    else if (b.t === "btn") {
      const href = hrefOf(b.href);
      if (!href) continue; // e.g. directions for an academy with no address
      blocks.push({ t: "button", label: b.label, href, primary: !hasWaiver });
      textParts.push(`${b.label}: ${href}`, "");
    }
    else if (b.t === "sign") {
      blocks.push({ t: "sign", lines: b.s });
      textParts.push(...b.s, "");
    }
    else if (b.t === "kept_email1_tail") {
      // KEPT FROM THE PREVIOUS CONFIRMATION: bring-a-friend, and the academy's
      // phone (in the HTML, the phone is in the layout's footer).
      blocks.push({ t: "p", parts: [], lines: [["Bring a friend — their first class is free too."], ["Send them here: ", { text: trialUrl, href: trialUrl }]] });
      textParts.push("Bring a friend — their first class is free too.", `Send them here: ${trialUrl}`, "");
      const signoff = "myBJJ " + vars.location + (v.unitPhone ? " · " + v.unitPhone : "");
      textParts.push(signoff, "");
    }
  }
  const unsub = v.unsubscribeUrl || "";
  const footerText = "You're getting this because you booked a free trial at myBJJ.";
  textParts.push(footerText, ...(unsub ? [`Don't want these emails? Unsubscribe: ${unsub}`] : []));
  const subject = fill(tpl.subject).replace(/[\r\n]+/g, " ");
  const html = renderLayout({
    subject,
    blocks,
    footer: { academy: v.location || null, address: v.addressLine, mapsUrl: maps, phone: v.unitPhone, why: footerText, unsubscribeUrl: unsub || null },
  });
  return { subject, html, text: textParts.join("\n") };
}
