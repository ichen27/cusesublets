# Cloudflare deployment and provider setup

The initial edge deployment below is a setup guide; the current Mac mini deployment is documented in the dated sections later in this file. No edge Worker deployment has been performed. `npm run deploy:check` builds and packages the Worker without provisioning or publishing resources. The checked-in D1 ID is an explicit local placeholder. A successful dry run is not evidence of live authentication or financial integrations.

## Infrastructure

1. Choose the Cloudflare account and custom domain. Create a D1 database named cusesublets and a private R2 bucket named cusesublets-private using the account dashboard or current Wrangler resource commands.
2. Replace the D1 placeholder in wrangler.jsonc with the returned database ID. Confirm bucket name and Worker name target the intended account. Keep APP_ENV=production.
3. Apply only migrations/ to the remote database. Never apply seeds/demo.sql remotely; seed is local demo content.
4. Configure APP_ORIGIN as the exact HTTPS app origin. Configure ACCESS_TEAM_DOMAIN as team.cloudflareaccess.com and ACCESS_AUD as the Access application audience.
5. Set ADMIN_EMAILS to a comma-separated explicit reviewer allowlist. The Worker validates issuer, audience, expiry and signature before deriving staff role. Do not treat arbitrary identity headers as authentication.
6. Review files and settings, run npm run types, npm run typecheck, npm test, npm run deploy:check; deploy only when authorized.

## Cloudflare Access + Google

Set up a self-hosted Access application protecting `/api/login` with Google as the identity provider and the intended customer allow policy. The app's login button navigates there; the validated Worker identity redirects back to `/#account`. Make sure the authorization cookie is sent on the app origin for API requests. Public catalog and static assets remain anonymously accessible. The Worker still validates JWTs and checks ownership/roles on every private endpoint; Access login alone is not authorization. Use an additional staff Access policy for the admin surface if desired, without bypassing Worker role checks. Test logout, expiry, guest browsing and ordinary-member denial of admin APIs on the actual configured domain before launch.

## Financial and signing integration boundaries

Current payment/sign routes are explicitly local simulations. Implement a selected provider behind those boundaries before enabling real transactions. For Stripe, use an approved Connect marketplace flow; server-created checkout amounts, verified webhook signatures and idempotent event records must be authoritative. A success URL must never mark a booking paid. Connect account onboarding and payout readiness must precede checkout. Implement refunds, transfer reversals and dispute accounting before release. The proposed 48-hour post-move-in rule is a product proposal, not a guarantee of bank settlement or protection from chargebacks. Stripe does not provide escrow.

Agree which fees/rent are collected, when cards are charged, when the renter can cancel, and who funds refunds. The sample total uses a 30-day proration purely to demonstrate the UI. Do not reuse that convention for live contracts without approving it.

Identity must be for an approved fraud-prevention use. Stripe Identity prohibits using results to decide housing eligibility; get provider confirmation for this use case. Do not collect government ID through generic uploads. Replace demo acknowledgments with a provider-driven document/signature workflow that stores document version, consent, audit evidence, final artifact and provider webhook status.

## Media and maps

Matterport tours use allowed HTTPS my.matterport.com/show/ URLs with a model ID. Capture happens in Matterport, then attach its share URL. A video upload stays video; no reconstruction is claimed. Check Matterport plan/embedding requirements for launch. Review images/videos for rights and personal information.

The preview uses standard OpenStreetMap tiles with visible attribution and normal browser caching. No prefetch or offline map download. Select a production map provider and reliable approximate-location geocoding before public traffic; listing coordinates are host-selected on a map and rounded to three decimal places, not address verification. The API defaults to central Syracuse when coordinates are omitted. Configure external photo/font/map privacy disclosures. Private document downloads use no-store and attachment disposition.

## Launch readiness

Exercise real Google login and staff allowlist; set up appropriate rate limits and abuse controls; add retention/deletion policy and malware/media validation; define reviewed sublease/permission rules with counsel; test provider webhooks and retries in sandbox; exercise reporting/suspension and add refund support. Monitor Worker logs/traces without logging message bodies, documents or provider secrets.

Official references checked during development:
- https://developers.cloudflare.com/workers/static-assets/
- https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/
- https://developers.cloudflare.com/d1/worker-api/d1-database/
- https://docs.stripe.com/connect/manual-payouts
- https://stripe.com/legal/ssa-services-terms
- https://operations.osmfoundation.org/policies/tiles/

## Mac mini hosted private preview — September 17, 2026

URL: https://app-cusesublets.chenagent.com (also registered in https://apps.chenagent.com).
The existing Cloudflare Access Google policy restricts entry to the owner. The launcher independently verifies Access JWTs and strips them before proxying; CuseSublets does not treat this as a marketplace account.

The launchd job `com.chenagent.launcher.app.cusesublets` runs `launcher-run.sh` on loopback port 8918 with `APP_ENV=hosted-preview`. It uses Wrangler/workerd local emulation on the mini, not a deployed edge Worker. This is a browsing-only sample preview. All API routes except GET session/listings/listing detail are denied. Demo roles and transactions remain available only through the separate local development preview on 8917.

Persistent sample D1/R2 data: `/Volumes/SamsungSSD1/tools/app-launcher/apps/cusesublets/state`. Never point both runtimes at the same persistence directory. Logs: `/Volumes/SamsungSSD1/tools/app-launcher/logs/cusesublets.{stdout,stderr}.log`. Launchd resumes after login and SSD mount; the mini must remain online.

Update after building with `npm run build`, then run from the app-launcher directory:

```sh
/opt/homebrew/bin/node src/cli.mjs deploy /Volumes/SamsungSSD1/code/cusesublets/launcher.json
/opt/homebrew/bin/node src/cli.mjs status cusesublets
```

Stop or restart with `node src/cli.mjs stop cusesublets` / `restart cusesublets`. Stop disables automatic startup without removing data or DNS. Source rollback requires restoring the desired commit and rebuilding before redeploying; launcher manifest rollback does not restore source/assets. Existing tunnel routes and other apps are unchanged.

To initialize a new preview datastore before starting it, apply migrations and `seeds/demo.sql` using Wrangler `--local --persist-to` with the exact state directory above. Do not apply sample seed to a real production database. See https://developers.cloudflare.com/workers/local-development/local-data/ for local persistence behavior.

Validated: 16 unit tests, TypeScript, production asset build; real launchd deploy; six sample listings and detail HTTP 200; hosted session has no user and demo=false; writes, private APIs, login and demo-admin endpoint denied; gateway missing-JWT 401; anonymous HTTPS curl redirects to Access; authenticated browser renders sample catalog and private-preview label. Python urllib received edge 403 while curl received the expected Access 302; browser access succeeded.

## Current private beta — September 17, 2026 (supersedes browsing-only mode)

User requested enabling Google login, listing submission, communication, offers and date requests on the hosted app, plus filtering the catalog by the visible map viewport.

`launcher-run.sh` now runs with APP_ENV=staging, existing Access issuer/audience and an explicit owner admin allowlist. A specific tunnel ingress for app-cusesublets.chenagent.com goes directly to 127.0.0.1:8918, before the wildcard launcher route. This preserves the signed Access JWT for validation by the CuseSublets backend. The owner-only Access policy is unchanged. The launcher still manages the app service/card; it is no longer the request proxy for this hostname. Other apps retain their existing routing. Tunnel backup: ~/.cloudflared/config.before-cusesublets-auth-20260917.yml.

The local Wrangler proxy rewrites same-host HTTPS Origin to HTTP before Worker execution. The mini launch command therefore uses APP_ORIGIN=http://app-cusesublets.chenagent.com for exact origin validation; public TLS stays HTTPS. Edge deployment must use the actual HTTPS origin. Forged JWTs/email headers, cross-site writes and unauthenticated private routes are rejected. Demo-session endpoint remains disabled. Signatures and payment simulation remain local-demo-only; no live payment provider was enabled.

Google sign-in automatically creates the account; the profile button replaces Log in when an existing Access session is valid. New listings stay pending until reviewed. Messages/offers persist in Inbox; visible inbox data refreshes every 10 seconds and on window focus. Offers and asking-price date requests share the host acceptance flow. Sample host accounts do not represent real people and will not reply automatically. Additional testers need a CuseSublets-specific Access application/policy; never widen the shared personal-app policy to expose unrelated apps.

The map emits viewport bounds after pan, zoom, and visible resize. Only catalog results are clipped; map markers retain all candidates satisfying other filters, so zooming out restores results. Hidden mobile maps do not publish zero-size bounds. Initial map view fits sample homes once; later filtering does not move the map.

Validation: 20 unit tests; TypeScript; build; existing local API runtime flow; tests/hosted-guards.py against the real 8918 service. Authenticated hosted browser verified account, saved sample message, $750 offer and $785 asking-price request in Inbox, pending test listing in account, and map results shrinking from six to three on mobile and six to two on desktop. Test listing is explicitly named "Private beta test listing — not available" and left pending; no real property or payment created.

Rollback to browsing-only: restore launcher-run.sh APP_ENV=hosted-preview, rebuild/restart via launcher; optionally remove only the exact CuseSublets tunnel rule and restart cloudflared. Never blindly restore an old full tunnel config after other service changes.

## Conversation workspace — September 17, 2026

Listing message, offer, and asking-price request actions open a persistent full conversation. Threads have listing context/backlink, PDF/JPEG/PNG document sharing, proposal/counteroffer cards, and booking steps. My listings is now a main navigation destination with host conversations, proposals to review, reservations and private review-document uploads. Profile has editable display name. Hosted legal e-signing and Stripe payment buttons explicitly remain unavailable pending provider integration; demo acknowledgments/payments stay local-only.

Apply migration 0004_conversations.sql with the service stopped. It backfills listing/buyer conversations and legacy proposals without deleting existing records. Back up the exact hosted state directory first. Do not seed the hosted database during updates. Tests run separately on port8920 with .wrangler-chat-test state.

Verification: 20 unit tests, typecheck/build, legacy API runtime and new chat runtime (participant isolation, document validation/private downloads, legacy backfill, counteroffer and acceptance races); independent code review with race and booking-control fixes; browser listing-to-chat, message, request, host My listings, counteroffer, property backlink, refresh persistence and 390px layout.

Live rollout: backup state-before-chat-20260917 beside hosted state; service stopped, migration 0004 applied, service started successfully. The separate 8917 demo datastore was also migrated while stopped and restarted. Hosted guard suite (5 tests including conversations and chat-document authentication) passes. Signed-in browser confirmed one preserved pending test listing under Ivan Chen in My listings; account name changed from email stem via profile form. No real property was published. Owner-only Access remains unchanged.

## Profiles and independent checks — September 17, 2026

New listings are published immediately with unverified identity/lease/permission states. Existing unpublished/test/moderated listings are preserved. Evidence uploads reset the relevant check without altering publication status; uploads cannot revive paused/rejected listings. Reservation/payment eligibility still requires all review prerequisites. Admin publication decisions are separate from evidence decisions. Verification requires current evidence IDs, audit reasons and another reviewer for a reviewer’s own identity/listing.

New account editor: name, Google email (read-only), private phone, public bio/social links, profile picture/gallery and private ID submission. Public host profile projects only selected public fields and offers other listings and completed-lease reviews. Review eligibility requires counterpart participation, elapsed lease, paid reservation, move-in and no open dispute. Demo paid only qualifies in local development. ID files are private owner/admin-only attachments with no-store headers. Profile images have separate public routes; replacing/removing photos retires old URLs. Profile name changes invalidate identity and require new evidence.

Shared CuseSublets Checks panel replaces inconsistent trust copy. Header How it works popup removed; footer checks guide is a full page. Styled file cards support selecting/dropping files with success/error state and clear private/public distinction.

Apply migration0005_profiles.sql while each intended runtime is stopped; back up hosted state first. Isolated tests use8921/.wrangler-checks only. Validation:20 unit tests, typecheck/build; legacy/chat/profile runtime suites covering evidence privacy/staleness, encoded Access IDs, self-review blocks, avatar retirement, publication separation and review eligibility; independent review fixes completed; browser profile/ID submission/manual review/public host profile plus desktop390px upload layout. Test IDs were synthetic files only.

## Public browsing enabled — September 17, 2026

The page-level login comes from the shared Personal App Launcher Access app (`6b947c90-9cfc-4960-b367-3dfaae2b47e9`) covering `app-*.chenagent.com`. An explicit `app-cusesublets.chenagent.com/api/login` destination has been added to the same app, preserving its audience and Google owner allow policy. The app already accepts the signed CF_Authorization cookie on private APIs and verifies issuer, audience, signature and expiry. Identity/lease checks are separate from login.

Activated with user confirmation: dedicated public browsing Access application `2dd1bf1d-4496-4280-9f24-423397cede24` for exact hostname `app-cusesublets.chenagent.com`, using Bypass/Everyone policy `04d00b00-da37-4624-9b9b-941d70f33402`. The more-specific `/api/login` destination remains protected by the existing Google policy; no bypass was attached to the shared personal-app policy.

Verified over public HTTPS: anonymous root/listings/session return 200, session user is null, profile/conversations/admin APIs return 401, login returns 302. Browser verified signed-out catalog, explicit Google login returning to Ivan's account, and logout returning to the public catalog. Five hosted guard tests pass. Google login remains owner-only until a dedicated customer sign-in policy is configured.

GitHub is now https://github.com/ichen27/cusesublets (private), default `main`; CLI authentication on the mini is restored. GitHub checks pass. Never commit live databases or uploads.

## Email/password login — September 17, 2026

Deployed email/password signup/login alongside Google. Migration 0006 adds private credential hashes, hashed expiring sessions and atomic rate counters. Public signup creates unverified members only. Existing-email collisions never auto-link. Staff password login was provisioned offline for the existing Ivan account with its current admin role; no duplicate identity or verification badge was created. Credentials are never stored in Git or notes.

New routes: POST /api/auth/signup, /api/auth/login, /api/auth/password; authenticated GET /api/auth/status. Change password requires an email/password session and the current password, revokes all password sessions and issues a new current session. Google sessions are independent. Automated email verification and forgotten-password email delivery are not configured.

Hosted service8918 was stopped, state backed up to state-before-password-20260917, migration applied, and service restarted. Local demo8917 was also migrated and restarted. Validation:21 unit tests, typecheck/build,4 isolated runtime tests (including concurrent password rotation),5 hosted guard tests, independent spec/quality reviews. Browser verified member login, refresh persistence, logout, corrected account navigation and change-password controls. Live HTTPS staff login/admin access, credential rotation, revoked sessions, final login and logout all passed. Google-backed account still loads.
