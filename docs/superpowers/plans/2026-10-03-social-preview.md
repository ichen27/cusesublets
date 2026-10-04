# Social community browser preview implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. This is a reversible isolated prototype explicitly requested by Ivan, not production implementation of the full social backend.

**Goal:** Let Ivan experience the approved visual direction as a responsive working website.
**Architecture:** Separate Vite entry under prototype/, using existing React, Lucide and Leaflet dependencies. Fictional records and browser-local state; no production API calls. Existing app and data stay untouched.
**Tech stack:** React, TypeScript, CSS, Leaflet, Vite.
**Spec:** ../specs/2026-10-03-social-community-design.md; prototype scope below controls delivery.

## Constraints and scope
- Three-column desktop: filters/map, feed, search status and matches. Mobile responsive feed with bottom navigation. Orange/plum/lavender, serif headlines, no handwriting or doodles.
- Browser preview includes welcome/role selection, skippable short questionnaires, Browse interactions, public comment simulation, like/save, listing detail, map, two-sided sample Matches, private message simulation and You controls.
- Persist drafts, status and sample interactions only in versioned localStorage. Clearly mark sample data and simulated messages. No document upload, real verification, authentication, payments or external messaging.
- Preserve canonical one-search model and independent offering/searching in the prototype. Search settings actually filter sample matches and map markers. No fake compatibility percentages.
- Show the prototype on a separate loopback port via SSH forward. Commit/push feature branch; do not merge/deploy production.

## Review focus
- Empty results and skipped setup have actionable states.
- Form values survive Back/Finish later and refresh.
- Comments and message drafts render as text; no untrusted HTML.
- Phone width has no horizontal overflow or hidden primary controls.
- Dialogs trap focus, close with Escape, restore focus; match contact warns for missing checks and never sends implicitly.

### Task 1: Visual shell and sample model
- [x] Create prototype/index.html, vite.config.ts, model.ts, main.tsx, styles.css; reuse installed dependencies, separate build output.
- [x] Render approved desktop layout and responsive mobile navigation with fictional photos and people clearly labeled.
- [x] Verify independent build and core typecheck; preserve existing app.

### Task 2: Interactive journey
- [x] Implement role choice, questionnaire steps, skip/resume, editable search status and sample listing publish/pause.
- [x] Wire feed filters/map, likes/saves/comments, focused Matches with fit reasons, You, and locally simulated Inbox.
- [x] Verify criteria and state via focused model tests; verify actual forms/browser interactions.

### Task 3: Verify and deliver
- [x] Build/typecheck/unit tests, desktop/mobile browser walkthrough, screenshot.
- [x] Fresh review of preview code, fix concrete findings once.
- [x] Push branch, check CI, run isolated mini preview, leave browser deliverable open and record in Obsidian.

## Completion record — October 4, 2026
Built as an isolated static preview on mini8931 and forwarded to the MacBook. Product data and production services untouched. Ruling: this request is for an interactive design preview; real social APIs, authentication, evidence submission and delivery are deliberately outside this deliverable and clearly labeled in the UI.
Fresh review by /root/preview_review found shared recipient drafts; fixed with per-recipient persisted drafts. Also kept incomplete search drafts separate from the active search, preserved pause state on listing edits, and labeled the mobile icon-only post action. Browser confirmed draft separation after refresh, private unfinished search edits, create/host-match and pause/edit status, local social actions, unverified notice, and mobile390 without overflow.
