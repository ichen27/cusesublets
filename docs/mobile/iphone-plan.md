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

The following remain release work, not implied by a successful build:

- Real-device camera/LiDAR, interruption/backgrounding, low-memory and room-quality tests.
- Physical-device signing, bundle ownership, provisioning and TestFlight/App Store distribution.
- End-to-end hosted Google authentication and any additional Apple sign-in/account-deletion requirements for the chosen distribution.
- Accessibility and full web/mobile parity review, including all discovery filters, comment editing, profile gallery management, completed-lease reviews and staff tools.
- Reliable photographic capture/reconstruction jobs and Gaussian-splat playback: the prior experiment showed artifacts and lacks independent quality validation. No fake or automatic completion state is presented.

Existing product limitations also remain: verified email/password recovery, legal signing and real payments are not configured on the website either. Native delivery does not create those capabilities. Push notifications are a separate mobile enhancement; none should be presented as already available.

## Next implementation slices

1. Finish the isolated native interaction flow, retain its screenshots, and resolve any failures before calling the app validated.
2. Close web/mobile parity gaps: complete discovery filters, editable comments, profile gallery management and completed-lease reviews. Keep staff administration accessible through the existing web workspace.
3. Test capture on a supported physical iPhone: repeat the same room, compare a few independently measured dimensions, interrupt capture and upload, and verify a private scan can be recovered after relaunch without publishing it.
4. Integrate photographic reconstruction as its own job lifecycle: capture/upload, processing, failure/retry, private review and explicit publication. Use the existing apartment reconstruction experiment as a starting point; evaluate artifacts and novel viewpoints before calling the result a tour. Keep original captures and virtual staging clearly distinguished.
5. Configure the owner's signing team and bundle identity, test hosted authentication and distribution requirements, and prepare a TestFlight build. TestFlight requires account/provisioning setup; the checked-in simulator project is not an installable phone package.

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
- [ ] Step 1: Marketplace parity — discovery filters, map viewport and people areas, relevant/latest ordering, comment editing, profile gallery removal, completed-lease reviews, and remaining native navigation gaps. Validate domain boundaries and UI interactions.
- [ ] Step 2: Photographic capture and reconstruction — inspect/reuse the existing experiment, implement private upload/job/failure/retry/review/publication, and connect actual viewer/export artifacts. Validate privacy and real processing; report quality limits.
- [ ] Step 3: Authentication and lifecycle — expiry/suspension coverage, account deletion and distribution authentication requirements, background/relaunch recovery, and hosted auth verification.
- [ ] Step 4: Accessibility and delivery — labels/Dynamic Type/error recovery, app assets and portable release configuration, current CI and independent review.
- [ ] Step 5: Supported-device capture accuracy/recovery and signing/TestFlight. Requires the owner's iPhone details, physical-device evidence and Apple account/provisioning access.

Existing unavailable payments, legal signing and email-provider workflows remain separately identified product dependencies; do not simulate them as live capabilities. Android remains deferred by the iPhone-first decision.
