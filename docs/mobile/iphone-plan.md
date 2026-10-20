# iPhone-first CuseSublets

## Product decision (October 16, 2026)

The owner approved an iPhone-first version of the full marketplace, with public web listing pages retained. Reuse existing accounts, listing data and backend. Bring Browse, Matches, Inbox, profile/listing management, capture/upload and tour viewing into the mobile experience. Android comes later.

Room scanning connects to the existing apartment reconstruction and Blender experiments. Distinguish three outputs: approximate captured room geometry, photographic reconstruction, and edited/virtually staged presentations. None verifies identity, ownership, lease validity or permission to sublet.

## Architecture

- `ios/CuseSublets`: native SwiftUI screens, MapKit maps, RoomPlan capture, SceneKit geometry viewing. iOS 17 or later; capture checks LiDAR capability at runtime.
- `APIClient`: shared REST API, ephemeral URLSession, session cookies stored in device-only Keychain, no saved passwords, no cross-origin redirects.
- Google login: system authentication browser → existing Access-protected login → 60-second one-use code bound to a SHA-256 verifier → existing revocable eight-hour session. The custom callback carries a code, never a session token.
- Existing Worker/D1 data and authorization remain authoritative. Mutation Origin checks remain enabled. Native requests supply the configured origin; local Wrangler's origin rewriting remains documented separately.
- `room_scans`: bounded layout JSON, attached to an owned listing, private by default. Owner must explicitly publish. Public reads also require a published listing and an active owner. Publishing a scan does not change any check status.
- Browser listing pages show an approximate overhead layout. The iPhone app displays the same geometry in 3D. Existing Matterport and video links remain available.

## Implementation and release boundaries

This branch is an initial mobile implementation, not an App Store release. It includes native discovery, public profiles, matches, conversations/messages/documents/offers, account editing/check uploads, private bookmarks, comments/replies/reports, listing and search drafts, listing management and room capture/publication. Staff administration remains in the existing web workspace.

The implemented software now includes discovery filters and map areas, edited comments, profile gallery removal and completed-lease reviews; ARKit photographic capture, durable reconstruction jobs, playback and PLY export; Apple authentication, expiry/revocation handling and account deletion; member blocking/private reporting, privacy packaging and app assets.

The following remain release work, not implied by a successful build:

- Real-device camera/LiDAR, interruption/backgrounding, low-memory, accessible navigation and room-quality tests.
- Physical-device signing, bundle ownership, provisioning and TestFlight/App Store distribution.
- End-to-end hosted Apple/Google authentication, provider revocation and deployed account-deletion scheduling/backup handling.
- Operational support, moderation, privacy/retention and licensing decisions. The bundled notice is explicitly a synthetic-data development-preview notice.
- Independent real-room photographic quality and Blender importer checks; synthetic processing proves integration only.

Existing product limitations also remain: verified email/password recovery, legal signing and real payments are not configured on the website either. Native delivery does not create those capabilities. Push notifications are a separate mobile enhancement; none should be presented as already available.

## Remaining release sequence

Use [the release checklist](release-checklist.md) for the prepared signing procedure, physical-device matrix and deployment prerequisites. Complete software validation/review on the current revision, then perform the physical and hosted checks with the owner's device/account setup. Do not deploy migrations or enable the processor by merely merging into a watched checkout.

## Acceptance checks

1. Existing web checks pass, including unaffected migrations and concurrency tests.
2. iPhone simulator build and unit tests; simulator interaction test exercises browse, tabs, account creation and private draft persistence against isolated local data only.
3. Runtime API tests prove scan ownership, private/public behavior, listing pause revocation, unchanged checks, invalid input rejection and retry safety.
4. Mobile auth tests prove verifier binding, single use, expiry and logout; never test by publishing user property or uploading real identity documents.
5. Capture is explicitly unavailable on unsupported devices; never fabricate a successful scan in a simulator.
6. Capture results survive an upload failure locally and require explicit publication after upload.

## Completion sequence — resumed October 16

The owner asked to continue through all remaining parts one step at a time. Finish and validate each software slice, push it to PR 1, then advance. Physical validation and distribution are explicit gates, not things a simulator can substitute for.

- [x] Initial native interaction flow and reproducible simulator evidence.
- [x] Step 1: Marketplace parity — discovery filters, map viewport and people areas, relevant/latest ordering, comment editing, profile gallery removal, completed-lease reviews, and remaining native navigation gaps. Validate domain boundaries and UI interactions.
- [x] Step 2: Photographic capture and reconstruction — inspect/reuse the existing experiment, implement private upload/job/failure/retry/review/publication, and connect actual viewer/export artifacts. Validate privacy and real processing; report quality limits.
- [ ] Step 3: Authentication and lifecycle — expiry/suspension coverage, account deletion and distribution authentication requirements, background/relaunch recovery, and hosted auth verification. Software is implemented and simulator-tested; hosted provider verification is pending.
- [ ] Step 4: Accessibility and delivery — labels/Dynamic Type/error recovery, app assets and portable release configuration, current CI and independent review.
- [ ] Step 5: Supported-device capture accuracy/recovery and signing/TestFlight. Requires the owner's iPhone details, physical-device evidence and Apple account/provisioning access.

Existing unavailable payments, legal signing and email-provider workflows remain separately identified product dependencies; do not simulate them as live capabilities. Android remains deferred by the iPhone-first decision.
