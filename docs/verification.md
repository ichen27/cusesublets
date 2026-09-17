# Verification — September 16–17, 2026

All implementation and tests ran on the Mac mini at `/Volumes/SamsungSSD1/code/cusesublets`, branch `feat/initial-marketplace`.

## Automated checks

- TypeScript project check passed.
- Vitest: 16 tests passed across API policy, discovery date/filter behavior, and payment-state presentation.
- Expanded `tests/api-runtime.py` passed against local Wrangler: authentication and CSRF, ownership, draft privacy, private R2 files, media publication, specific evidence review invalidation, private reviewer notes, identity changes, offers, overlap guards, demo agreement/payment actors, move-in/disputes, audit immutability, listing reports, suspension/restoration and preserved dispute access.
- In-memory SQLite review independently verified suspension triggers guard offer, booking and payment writes for either suspended participant.
- Vite production build passed (about 132.5 KB gzipped JS, 15.3 KB CSS).
- Wrangler deploy dry run passed. This verifies packaging only; no production resources were provisioned or deployed.

## Browser checks (real Chromium through Playwright CLI on mini)

1440×1100 desktop and 390×844 mobile:
- Home renders listing cards and map, remote photos/font/tiles load. Final mobile viewport has scrollWidth 390 and innerWidth 390; no broken images.
- Neighborhood filter narrows catalog and marker set. Budget/date/room filters have unit coverage, including past/future one-sided intervals.
- Renter login, listing detail, private message, monthly offer and requested dates submitted through UI.
- Host accepts offer; each party acknowledges the demo agreement; renter simulates payment and confirms move-in through UI.
- Renter files a dispute and admin resolves it. Final persisted sample booking: status `moved_in`, payment `demo_paid`, moveInAt present, dispute `resolved`.
- Host completes all three listing form steps; created draft appears privately in account. Admin selects it and requests missing documents with a reason. Final status `needs_info`, lease and permission both `pending`.
- Mobile map/list toggle works. Moved toggle out of fixed overlay after screenshot caught search-button overlap.
- Admin review screenshot inspected; private evidence and two separate verification inputs visible with decision/reason controls.

Screenshots are in local `work/`: desktop-final.png, mobile.png, mobile-map.png, admin.png and reservation.png. They show sample listings and simulated activity, not real housing/transactions. Selected screenshots are copied to the user's deliverables folder.

## Findings corrected

Independent backend review found internal review-note exposure and evidence uploads retaining old verification. Public DTO projection and atomic review reset fixed both. Frontend review found a `paid`/`demo_paid` mismatch, one-sided date-filter bugs and inability to remove failed media after a partial upload; all corrected with appropriate regression checks. A Syracuse-local calendar regression covers midnight UTC. The map provider initially returned an API-key watermark; the preview now uses OpenStreetMap tiles with attribution.

## Operational notes and limits

An initial second Wrangler process sharing local SQLite caused a dev-runtime database lock. The duplicate CuseSublets test server was stopped. Exactly one primary preview process now serves 127.0.0.1:8917; use its API for local testing or a separate persistence directory. No unrelated service was stopped. Port 8791 belongs to another app and is not used.

No verification of live Google Access policy, Stripe payments/webhooks, identity SDK, e-signing or payouts is claimed. Those integrations and operator policies remain launch work, documented in deployment.md. No actual funds or legally binding signatures were created.
