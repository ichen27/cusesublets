# CuseSublets My Activity and Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace repeatable seeker posts with one profile-linked housing search, make My activity the home for listings and search, and connect map discovery and two-way matches to the same criteria.

**Architecture:** Retain `seeker_requests` IDs for conversation/report history and mark one canonical search row per owner. Put polygon geometry and housing fit in pure shared modules, then use those modules in Worker APIs and React views. Browse, My activity, and Top Matches consume one public/owner search projection and preserve existing listing and chat rules.

**Tech Stack:** React 19, TypeScript, Leaflet, Cloudflare Worker/D1, Vitest, Python runtime tests, Playwright CLI.

**Spec:** `docs/superpowers/specs/2026-10-02-my-activity-search-design.md`

## Global Constraints

- Work on the Mac mini SSD in `/Volumes/SamsungSSD1/code/cusesublets`; preserve the stable `main` checkout and existing data.
- On the mini, use `export PATH=/opt/homebrew/bin:$PATH` before npm, Wrangler and GitHub CLI commands.
- Browse remains public; owner writes and Top Matches require sign-in. Public projections exclude email, phone, and private documents.
- A member can offer a published listing and run one active housing search simultaneously. Editing or toggling that search retains its ID and original feed order.
- Places use approximate listing coordinates. People maps show desired areas, never pins implying a person's current address.
- Keep CuseSublets Checks and listing publication rules independent; identity and demographic data are not match inputs.
- Use the existing Syracuse map-selection envelope from `src/MapPicker.tsx`: latitude `42.9..43.15`, longitude `-76.3..-75.95`.
- Apply migration 0009 to isolated, demo, and hosted persistence directories separately. Back up each real directory with its service stopped; never seed hosted state.

## Review Focus

1. Multiple legacy requests, including a removed one: migration preserves IDs/conversations and chooses one off canonical row without reviving removed content (Task 3 runtime test).
2. Polygon edges cross a viewport while no vertex lies inside: People mode includes the person once (Task 1 unit test).
3. Self-intersecting or out-of-envelope areas: write returns 400 without changing the stored search (Task 3 runtime test).
4. A search is turned off after a match was displayed: new host contact is denied but its existing conversation remains accessible (Task 4 runtime test).
5. A member has both a live listing and a search: both activity cards and both match-source choices remain available; own listing never matches own search (Tasks 2, 5 and 7 checks).

## File map

- `shared/geo.ts`: `SearchArea`, bounds, area validation and polygon/viewport tests. `shared/types.ts`: `HousingSearch` and public criteria fields.
- `shared/matching.ts`: one `matchListingToSearch` function for both directions; `tests/geo.test.ts` and `tests/matching.test.ts` exercise pure rules.
- `migrations/0009_profile_search.sql`: canonical marker and unique owner index. `worker/index.ts`: search CRUD/projection, legacy-route transition, matches, contact and moderation. `tests/housing-search-runtime.py`: isolated real-Worker flow and migration assertions.
- `src/SearchAreaPicker.tsx` and `src/SearchEditor.tsx`: Leaflet area drawing/viewport capture and criteria form. `src/MyActivity.tsx`: listing and search management; reuse existing host controls from `src/HostWorkspace.tsx` through a focused exported section.
- `src/Browse.tsx`: mixed cards, filters and viewport/map modes. `src/MapView.tsx`: place pins and desired-area overlays. `src/Matches.tsx`: the two source modes and reasons. `src/PublicProfile.tsx`, `src/Workspace.tsx`, `src/App.tsx`, `src/styles.css`: navigation, public status, redirects and responsive layout. Retire `src/PostRequest.tsx` and the old `src/Discovery.tsx` after equivalent flows move.
- `docs/API.md`, `docs/deployment.md`, `README.md`: route, migration and user-flow documentation.

### Task 1: Geometry and area validation

**Files:** Create `shared/geo.ts`, `tests/geo.test.ts`; modify `src/MapPicker.tsx` to import shared `SERVICE_BOUNDS`.

**Interfaces:** Produce `type SearchArea = { id: string; label: string; points: { lat: number; lng: number }[] }`; `type GeoBounds = { south: number; north: number; west: number; east: number }`; `validateAreas(input: unknown): SearchArea[]`; `pointInAnyArea(lat: number, lng: number, areas: SearchArea[]): boolean`; `areasIntersectBounds(areas: SearchArea[], bounds: GeoBounds): boolean`. Validate 1–5 areas, 3–25 points each, finite coordinates inside `SERVICE_BOUNDS`, no self-intersection, nonempty label ≤80 characters; do not close polygons by duplicating the first point.

- [ ] **Step 1: Write failing geometry tests.** In `tests/geo.test.ts`, assert a point inside one polygon is included, an outside point is excluded, a polygon edge crossing a viewport is included once, and malformed/self-intersecting/out-of-envelope/over-limit input throws.
- [ ] **Step 2: Verify red.** Run `npx vitest run tests/geo.test.ts`; expect missing exports or failed assertions.
- [ ] **Step 3: Implement the four exported functions and bounds constant.** Use point-in-polygon plus segment intersection and containment for rectangle overlap; keep the module independent of Leaflet and Worker globals.
- [ ] **Step 4: Verify green and commit.** Run `npx vitest run tests/geo.test.ts && npm run typecheck`; expect pass. Commit geometry, tests and shared bounds.

### Task 2: Housing-search criteria and two-way fit

**Files:** Modify `shared/types.ts`, `shared/matching.ts`, `tests/matching.test.ts`.

**Interfaces:** `HousingSearch` contains stable ID, owner public name/identity, `status: "active" | "paused" | "removed"` (the UI calls `paused` “off”), dates, `minBudget?: number`, `maxBudget: number`, `minBedrooms?: number`, `roomType`, `requiredAmenities: string[]`, `preferredAmenities: string[]`, `areas: SearchArea[]`, public introduction, timestamps. Produce `matchListingToSearch(listing: Listing, search: HousingSearch, today?: string): MatchResult | null` with `score` and `reasons`; existing `matchListingToRequest` remains only until Task 4 migrates callers.

- [ ] **Step 1: Add failing tests.** Cover full date coverage, inclusive min/max rent, compatible type, minimum bedrooms for entire places, every required amenity, preferred-amenity score, approximate listing point inside an area, expired/paused/own exclusion, and deterministic ties. Assert reasons explain area, budget and dates without percentages.
- [ ] **Step 2: Verify red.** Run `npx vitest run tests/matching.test.ts`; expect new tests to fail.
- [ ] **Step 3: Implement the type and pure fit function.** Use Task 1's `pointInAnyArea`; make hard requirements return `null`, then score preferences and use ID tie-breaks in the route.
- [ ] **Step 4: Verify green and commit.** Run `npx vitest run tests/matching.test.ts && npm run typecheck`; expect pass. Commit the shared model and tests.

### Task 3: Canonical search migration and API

**Files:** Create `migrations/0009_profile_search.sql`, `tests/housing-search-fixtures.sql`, `tests/housing-search-runtime.py`; modify `worker/index.ts`, `docs/API.md`.

**Interfaces:** Add `profileSearch INTEGER NOT NULL DEFAULT 0` and unique partial index on `ownerId WHERE profileSearch=1`. Add `GET /api/my-search` → `{search: HousingSearch|null}`, `POST /api/my-search` → upsert criteria on the canonical row without changing `createdAt`, `POST /api/my-search/status` → `{status:"active"|"paused"}`, and public `GET /api/searches` → active canonical projections. Keep GET `/api/requests` and GET `/api/requests/:id` as public read aliases; legacy create/edit POST returns 410. API validation maps `validateAreas` failures to 400. New account with no search gets its canonical row on first complete save; removed canonical rows cannot be replaced by owners.

- [ ] **Step 1: Write a failing isolated runtime suite.** Assert guest reads only public fields, guest/nonowner writes fail, one owner save/edit/off/on keeps ID and `createdAt`, a second create path cannot add public rows, invalid polygon writes leave stored data unchanged, expired/suspended/removed searches stay private, and old POST returns 410. Test migration with active, paused and removed legacy rows plus a referenced conversation: one canonical off, older rows retained, conversation still readable, removed content not revived.
- [ ] **Step 2: Verify red in an isolated `:8925` Wrangler runtime.** Apply migrations 0001–0008 and `tests/housing-search-fixtures.sql` before 0009 for the migration case; run `API_BASE=http://127.0.0.1:8925 python3 tests/housing-search-runtime.py`; expect failure on missing API/migration. Keep this state under `/Volumes/SamsungSSD1/tools/cusesublets/activity-test`.
- [ ] **Step 3: Implement migration and endpoints.** Set legacy active/paused/closed canonical rows to `paused`, keep removed rows `removed`, select canonical per spec priority, preserve all IDs/reports/conversations, and enforce owner/staff rules and server-side field bounds.
- [ ] **Step 4: Verify green and commit.** Recreate isolated state and rerun the runtime suite, then `npm run typecheck && npm test`; expect pass. Commit schema, API, tests and contract docs.

### Task 4: Matches, contact and moderation use canonical searches

**Files:** Modify `worker/index.ts`, `tests/housing-search-runtime.py`, `src/Admin.tsx`.

**Interfaces:** `GET /api/matches?sourceType=search&sourceId=<canonical-id>` returns matching listings for the owner; `sourceType=listing` returns matching active canonical people. Existing `sourceType=request` may read the canonical row during transition. `POST /api/conversations` with `requestId` requires a current active canonical search and `matchListingToSearch`. Reports keep request IDs; admin restore sets canonical search to paused/off.

- [ ] **Step 1: Add failing runtime assertions.** Exercise both match directions, own-listing exclusion, expired/removed/suspended exclusion, one result per person, contact denial after search off, existing-conversation access after off, and staff remove/restore with audit and off state.
- [ ] **Step 2: Verify red.** Run the isolated `housing-search-runtime.py`; expect new assertions to fail.
- [ ] **Step 3: Switch Worker match/contact queries to canonical searches.** Keep the same listing-anchored conversation and report foreign keys; update Admin copy from posts to searches.
- [ ] **Step 4: Verify green and commit.** Run isolated runtime suite, `npm run typecheck && npm test`; expect pass. Commit API integration and tests.

### Task 5: Search editor and My activity

**Files:** Create `src/SearchAreaPicker.tsx`, `src/SearchEditor.tsx`, `src/MyActivity.tsx`; modify `src/HostWorkspace.tsx`, `src/App.tsx`, `src/styles.css`.

**Interfaces:** `SearchAreaPicker({value,onChange})` edits `SearchArea[]` with point drawing, labels, inspect/redraw/undo/remove and Add visible area; list controls remain operable without drawing. `SearchEditor({search,onSaved,onClose})` edits criteria and calls My search API. `MyActivity({user,onPost,onListing,onChat})` renders independent My subleases and My search sections, using HostWorkspace listing controls without nesting a second `<main>`.

- [ ] **Step 1: Record failing browser acceptance checks.** Against isolated `:8925`, check `#activity` for separate My subleases and My search cards, and check off → setup → save/on → edit → off while a live listing remains visible.
- [ ] **Step 2: Verify red.** Use the Playwright CLI snapshot at isolated `:8925/#activity`; expect My activity/search controls to be absent.
- [ ] **Step 3: Build components and responsive styles.** Reuse Leaflet tile/attribution behavior; show public-field guidance; redirect old `#host` to `#activity`; link Browse shortcut to My search setup.
- [ ] **Step 4: Verify green and commit.** Run browser flow at desktop and 390px plus `npm run typecheck && npm run build`; expect correct state and no horizontal overflow. Commit UI and styles.

### Task 6: Compact Browse and map-linked People results

**Files:** Create `src/Browse.tsx`; modify `src/MapView.tsx`, `src/App.tsx`, `src/search.ts`, `src/styles.css`; retire old Browse logic in `src/Discovery.tsx` after parity.

**Interfaces:** Browse takes `listings`, public `HousingSearch[]`, saved IDs and handlers; filters All/Places/People; `MapView` accepts optional highlighted `SearchArea[]` and selected-person ID. Places list uses existing listing bounds. People list uses Task 1's `areasIntersectBounds` and deduplicates by owner ID. Map/List switch preserves viewport and filters; map overlays never use a person's current-location pin.

- [ ] **Step 1: Add failing filter tests.** In `tests/search.test.ts`, assert viewport intersection includes edge-crossing people, excludes others, deduplicates one owner with two overlapping areas, and Places still tracks viewport without losing non-map filters.
- [ ] **Step 2: Verify red.** Run `npx vitest run tests/search.test.ts`; expect new assertions to fail.
- [ ] **Step 3: Implement Browse, map overlays, filters and responsive layout.** Keep the first content above the fold and the left filter panel from approved concept A; remove the large hero and separate Apartments top-level destination.
- [ ] **Step 4: Verify green and commit.** Run unit tests and desktop/mobile browser Browse flows; verify pan/zoom changes People results and card selection highlights its regions. Run `npm run typecheck && npm run build`; commit.

### Task 7: Top Matches, profile and navigation

**Files:** Create `src/Matches.tsx`; modify `src/PublicProfile.tsx`, `src/Workspace.tsx`, `src/App.tsx`, `src/styles.css`; retire `src/PostRequest.tsx` and remaining `src/Discovery.tsx`; update `README.md`.

**Interfaces:** Top Matches switches between active search and each owned published listing; seeker cards show matching listing pins in selected areas, host cards show matching people's desired-region overlays around the listing pin, and both show server-provided reasons. PublicProfile shows offering status from live listings and at most one active search summary. Desktop nav becomes Browse/Top matches/Inbox/Saved/My activity; mobile shows these five and avatar access to Profile. Existing hashes `#recent`, `#explore`, and `#host` map to Browse/Places/Activity respectively.

- [ ] **Step 1: Add failing navigation/state checks.** In a browser, assert anonymous Matches invites sign-in, off-search member is sent to My activity setup, seeker sees listing matches, host sees people for a chosen listing, both-role member can switch sources, and Profile shows only current public statuses.
- [ ] **Step 2: Verify red.** Run the checks against isolated `:8925`; expect outdated labels or missing states.
- [ ] **Step 3: Implement Matches, public profile projection and nav.** Preserve existing auth gates, account editor and hosted login behavior; remove post-oriented copy and dead UI.
- [ ] **Step 4: Verify green and commit.** Repeat browser checks at desktop and 390px; run `npm run typecheck && npm test && npm run build`; commit.

### Task 8: Full verification and rollout

**Files:** Modify `docs/deployment.md`, `README.md` with final runbook and feature description; no new runtime data in Git.

**Interfaces:** Feature branch is ready when isolated migration/runtime/browser checks and GitHub Checks pass. Stable main and running services update only after those gates. Hosted state `/Volumes/SamsungSSD1/tools/app-launcher/apps/cusesublets/state` and demo state `/Volumes/SamsungSSD1/code/cusesublets/.wrangler/state` remain distinct.

- [ ] **Step 1: Run fresh full verification.** `npm run typecheck && npm test && npm run build && git diff --check`; run existing `tests/hosted-guards.py` on loopback and the new isolated runtime suite. Confirm legacy conversation/report fixtures and responsive/map flows.
- [ ] **Step 2: Push feature branch and check GitHub Actions.** `git push` and `gh run watch <run-id> --exit-status`; expect success. Review the full branch diff and fix concrete findings.
- [ ] **Step 3: Preserve data and advance stable code.** Stop demo and hosted services, back up and verify each exact persistence directory, fast-forward/push `main`, build, and apply only migration 0009 to demo and hosted serially. Never run demo seed on hosted state.
- [ ] **Step 4: Restart and verify running services.** Deploy hosted through the launcher and restart the separate demo. Verify process listeners, anonymous HTTPS root/listings/searches, private-route guards, signed-in owner flows, map and both match modes. Record commit, migrations, backups and verification in deployment docs and Obsidian.

## Execution note

The tasks share model and API interfaces, so native sequential implementation is the recommended execution method. Keep completed, reviewed steps committed on the feature branch before advancing the live checkout.
