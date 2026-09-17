# CuseSublets Implementation Plan
> For agentic workers: use superpowers:subagent-driven-development for backend implementation and review; coordinator implements interface and integration.
**Goal:** Deliver a runnable Syracuse marketplace with persistent review and reservation workflows.
**Architecture:** React static assets and a TypeScript Worker; D1 storage and private R2 files. Single-origin API uses Access JWT in production and explicit localhost-only demo session for local testing.
**Tech Stack:** React, Vite, Leaflet, lucide-react, TypeScript, Wrangler, jose, Vitest, Playwright.
**Spec:** docs/superpowers/specs/2026-09-16-cusesublets.md
## Global Constraints
- All coding and tests run on mini SSD. Branch feat/initial-marketplace.
- Shared interfaces in shared/types.ts. API responses JSON, failures {error:string}; resources wrapped by plural key, individual resource by singular key.
- No live payments, public deployment, or actual verification claims in demo. Demo is localhost-only.

### Task 1: Worker application and persistence
Files: worker/*, migrations/*, tests/api*, docs/API.md. Consumes shared/types.ts; produces /api endpoints listed in docs/API.md.
- [ ] Write failing authorization and state-transition tests: guest POST =>401; member admin=>403; unreviewed checkout rejected; overlapping booking rejected; dispute blocks release.
- [ ] Implement schema, local seed and Worker route handlers with D1 prepared statements, R2 private reads and Access validation.
- [ ] Verify API tests locally against Wrangler and typecheck.
- [ ] Review security/state edge cases and commit.

### Task 2: Marketplace interface
Files: src/*, index.html, public/*. Consumes documented endpoints and shared types. Produces responsive discovery/detail, saved list, post, inbox/offers/bookings, account, admin.
- [ ] Build consistent layout and API client: fetch(path,{credentials:'same-origin'}), throw server error on !response.ok.
- [ ] Implement map/card selection, controlled filter state and empty/error/loading states.
- [ ] Implement workflow forms with server errors surfaced and submit disabled while pending.
- [ ] Browser-check filter narrowing, marker selection, detail, local login, listing submission and admin review.

### Task 3: Integration and deliverable
Files: README.md, docs/deployment.md, tests/e2e*, Wrangler/package configs.
- [ ] npm run typecheck && npm test && npm run build.
- [ ] Run migrations/seed only against local D1. Start preview, test member/admin flows and document isolation.
- [ ] npm run deploy:check; inspect desktop/mobile screenshots for clipping and accessibility.
- [ ] Record provider setup requirements and remaining production launch work; save context to Obsidian.
