# CuseSublets

A Syracuse-first sublease marketplace. Warm cream/orange React interface, interactive map and catalog, private messaging, offers, local reservations, and an admin review workspace. Cloudflare Workers hosts the API and built static assets; D1 persists records and R2 stores private review documents and guarded listing media.

## Run on the Mac mini

Canonical project: `/Volumes/SamsungSSD1/code/cusesublets`, branch `feat/initial-marketplace`. Start with `ssh mini`; shell commands below run in that directory. Node/npm on mini are under `/opt/homebrew/bin`.

```sh
export PATH=/opt/homebrew/bin:$PATH
npm ci
npm run db:local
npm run seed:local
npm run build
npm run preview:demo
```

Open `http://127.0.0.1:8917`. From the MacBook, forward the port with `ssh -N -L 8917:127.0.0.1:8917 mini` and open the same URL. Port 8791 belongs to an unrelated app; do not use or stop it.

Choose **Log in** or **Switch demo role** to try renter, host, or admin. Demo identities work only with `APP_ENV=development` and a loopback request hostname. Production defaults never expose demo sessions. Seed files contain clearly identified sample homes and illustrative Unsplash photos, not real offers.

### Try the flow

1. Search a neighborhood, set dates/budget, save a listing, or select a map pin.
2. As renter, open a listing, send a message or request dates at the asking rent / make an offer.
3. Switch to host, open Inbox → Offers and accept a nonoverlapping request.
4. Both roles acknowledge the demo agreement. The renter can simulate payment, confirm move-in on/after the start date, and report an issue.
5. As host, create a listing, upload photos/video and private lease/permission evidence. It stays pending.
6. As admin, review documents, record decisions with reasons, and inspect the audit log or disputes. New evidence resets its corresponding review and unpublishes the listing pending review.

## Checks

```sh
npm run typecheck
npm test
npm run build
npm run deploy:check
# With preview running; uses local demo records only:
API_BASE=http://127.0.0.1:8917 python3 tests/api-runtime.py
```

The runtime test creates local test records and pauses its listings, preserving the audit trail. Browser checks and screenshots are recorded separately in `docs/verification.md`.

## What works

- Public map/catalog with neighborhood, date, budget, room type, amenities, review and tour filters; local saved shortlist. Hosts choose an approximate listing pin.
- Listing details, photo gallery, validated Matterport embeds, direct media upload, and video player.
- Cloudflare Access JWT validation and explicit server-side admin email allowlist.
- Persistent listing submission, private document upload, review checklist and user identity review records.
- Separate identity, lease, permission statuses; private reviewer notes; append-only admin audit. Listing reports and audited account suspension/restoration preserve existing dispute access.
- Participant-only messages/offers/reservations, atomic overlap rejection, agreement/payment actor guards.
- Local demo reservation acknowledgments, simulated payment, move-in, dispute and payout-eligibility timeline.

## Explicit production limits

This is a runnable local MVP, not a launched financial marketplace. No Stripe Checkout/Connect account, identity-provider SDK, or legal e-signature provider has been connected. Payment and signing endpoints fail closed outside local demo; no actual money, escrow, signature, or ID verification is created. Admin identity review records a result supplied by an external review process. Payout eligibility is calculated, but the app never initiates a transfer or refund.

Live provider integrations and webhook handling, abuse controls, operator refund/dispute policies, identity-provider housing-use approval, legal agreement and privacy/retention terms, production map provider/geocoding, and operational support are required before accepting real users/documents/payments. Offer counteroffers/withdrawal, notifications and attachment sharing within conversations are not part of this first local build. Private documents currently support listing-review access only; no automatic sharing with renters.

See [deployment runbook](docs/deployment.md), [API contract](docs/API.md), and [approved design](docs/superpowers/specs/2026-09-16-cusesublets.md).

Run one Wrangler process per local persistence directory. Concurrent dev runtimes sharing .wrangler SQLite files can produce database locks. Use API_BASE against the existing preview for runtime checks.

## Hosted private preview

https://app-cusesublets.chenagent.com runs on the Mac mini through your existing Google-protected app launcher. Google identity now creates a marketplace account with listing submission, messaging, offers, date requests and admin review. Access remains owner-only until testers are explicitly added. Payments and legal signing are disabled; the local demo on 8917 remains separate. The catalog automatically follows the visible map area. See the deployment runbook for operations.

## GitHub workflow (September 17, 2026)

Source: https://github.com/ichen27/cusesublets (private), stable branch `main`. Development stays on the Mac mini SSD. Commit and push completed changes; GitHub Actions runs typecheck, unit tests and build for pushes and pull requests. Runtime data and credentials are excluded. Pushes do not automatically deploy the mini service. See AGENTS.md and docs/deployment.md.
