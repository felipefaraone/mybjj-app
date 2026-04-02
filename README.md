# myBJJ — Academy Management App

A fully functional web app for managing a Brazilian Jiu-Jitsu academy, built from scratch as a personal project to scratch my own itch as both a BJJ practitioner and a product manager who wanted a tool that actually fit how academies work day-to-day.

The app is a single-file SPA with zero dependencies — just vanilla HTML, CSS, and JavaScript.

---

## Why I Built This

Most gym management tools are either bloated, generic, or not adapted to the unique structure of a BJJ academy — belt systems, stripe milestones, gi vs. no-gi tracking, multi-audience class scheduling, and the informal but important culture around promotions.

I mapped the full product from scratch: user roles, data model, UX flows, and edge cases. I used Claude (AI coding assistant) to accelerate implementation, but every product decision, feature spec, and UX call was mine.

---

## Features

### For Students
- View weekly class schedule filtered by day and class type
- Track belt progression with IBJJF milestone indicators
- Log techniques with dates and filter by category
- View attendance history and journey timeline
- Read instructor feedback and evaluations
- See upcoming promotions and the Promotions Wall

### For Instructors / Admins
- Mark attendance per class with presence tracking
- Manage the full student roster with filters (belt, unit, near graduation)
- Add new, returning, or transfer students
- Create, edit, and delete classes in the weekly schedule
- Manage class details: duration, instructor, audience level (adults/junior/all)
- See which students are attending each session

### For the Head Professor (Owner)
- All admin capabilities
- Full staff management: profiles, journeys, roles
- Unit-level controls (multi-location support)
- Promotion management

---

## Tech Stack

| Layer | Choice |
|---|---|
| Language | Vanilla JavaScript (ES6+) |
| UI | HTML5 + CSS3 (no framework) |
| Architecture | Single-file SPA, state managed via a global `S` object |
| Fonts | Google Fonts (Barlow, Barlow Condensed, Bebas Neue) |
| Dependencies | None |

Going dependency-free was intentional — I wanted full control over every render cycle and no framework overhead on what is essentially a data-driven UI. It also makes the app trivially deployable: one file, anywhere.

---

## App Structure

```
index.html   ← entire app: markup, styles, logic, and sample data
README.md
```

The app uses a component-style render pattern: each "tab" is a pure function that returns HTML injected into the DOM. State mutations trigger re-renders manually, keeping the logic explicit and traceable.

---

## User Roles

| Role | Access |
|---|---|
| `student` | Schedule, personal progress, techniques, notifications |
| `admin` | + Presence tracking, roster management, class editing |
| `owner` | + Staff management, unit controls, promotion tools |

---

## Running Locally

No build step. Just open `index.html` in a browser.

```bash
git clone https://github.com/felipefaraone/mybjj-app.git
cd mybjj-app
open index.html
```

---

## Status

This is a working prototype built on sample data. It demonstrates the full product concept and UX. A production version would connect to a backend for persistent storage and real authentication.

---

## About

Built by **Felipe Faraone** — Senior Product Manager and BJJ practitioner.
Product design, feature prioritization, and UX were fully spec'd by me. Claude (AI assistant) was used as a coding accelerator for implementation.
