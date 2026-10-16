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
- Push notifications, verified email and password recovery, legal signing and real payments are not configured.

## Acceptance checks

1. Existing web checks pass, including unaffected migrations and concurrency tests.
2. iPhone simulator build and unit tests; simulator interaction test exercises browse, tabs, account creation and private draft persistence against isolated local data only.
3. Runtime API tests prove scan ownership, private/public behavior, listing pause revocation, unchanged checks, invalid input rejection and retry safety.
4. Mobile auth tests prove verifier binding, single use, expiry and logout; never test by publishing user property or uploading real identity documents.
5. Capture is explicitly unavailable on unsupported devices; never fabricate a successful scan in a simulator.
6. Capture results survive an upload failure locally and require explicit publication after upload.
