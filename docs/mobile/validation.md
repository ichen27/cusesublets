# iPhone validation — October 16, 2026

Latest completed simulator evidence: **`2a7bf1e` passed** [run38989941387](https://github.com/ichen27/cusesublets/actions/runs/38989941387), including the expanded marketplace flow and account lifecycle tests. Release-preparation changes after that revision require their own CI. Historical results below remain revision-specific; none establishes physical scan quality or App Store readiness.

## Verified

- [iPhone CI at b570d45](https://github.com/ichen27/cusesublets/actions/runs/38965186705) passed: build, two API runtime tests, all five native unit tests and the complete UI test.
- The UI test on an iPhone 17 Pro simulator exercised anonymous Browse/Matches/Inbox, manual email signup, secure session persistence, private listing draft save/resume, publication, the unsupported-scanner message and logout. All accounts and listings were synthetic and isolated. It does not capture a room.
- Native unit tests cover incomplete web drafts, anonymous sessions, column-major room transforms, Syracuse dates independent of device time zone, and Keychain save/read/delete.
- The two runtime tests cover scan ownership, private upload, explicit publication/hiding, revocation when a listing is paused, unchanged verification fields, malformed input and retry behavior; and mobile-auth verifier binding, one-use codes and logout.
- Web/Worker typecheck, all 45 unit tests and production web build passed locally and in [Checks at b570d45](https://github.com/ichen27/cusesublets/actions/runs/38965187243). The existing large JavaScript bundle warning remains.
- A signed simulator app and both test targets built locally with Xcode 27.1. Local native execution was interrupted when the mini's internal disk filled during simulator startup; the passing execution evidence comes from CI. Global developer-tool selection was unchanged.
- A browser check against the isolated API confirmed that a published synthetic layout renders on the public listing with zero console warnings/errors.
- Standards and spec review findings were corrected; see [review](review.md).

## Corrections established by the interaction tests

Earlier runs exposed an outer signup-toggle row that did not change the inner switch, Keychain storage failing in an unsigned simulator build, the system password-generation sheet covering manual input, and the email keyboard covering the next field. Signup now uses an explicit mode button, simulator tests use local ad-hoc signing, and the UI test dismisses keyboards before revealing lower fields. No insecure session-storage fallback was introduced.

The UI test selects manual password entry through a Debug-only environment switch. Normal signup retains new-password AutoFill, and Release ignores that switch. Password-manager interaction remains a separate device check. Earlier failures are retained in Git history and CI; they are not counted as passes.

The native workflow runs for pull requests and relevant pushes to main. This avoids competing feature-push and PR runs cancelling each other; older runs include cancelled duplicates.

## Unverified and release blockers

- Real LiDAR capture, local recovery after failed upload/relaunch, interruptions/backgrounding, low-memory behavior, accessibility and room geometry accuracy need device testing.
- Hosted Google/Access authentication, mobile-code expiry and suspended-account native flows are not covered by the two runtime tests.
- Signing team, provisioning, bundle ownership and TestFlight distribution are not configured. No physical iPhone was available for this run.
- Full marketplace parity and photographic/Gaussian reconstruction remain open in the [implementation plan](iphone-plan.md).

## Artifacts

These PNGs were inspected visually. Native screenshots come from the passing run at `b570d45`; the web layout uses a synthetic fixture. None demonstrates real-property capture accuracy.

| Artifact | Evidence |
| --- | --- |
| [Native Browse](screenshots/iphone-browse.png) | Public feed and native tabs |
| [Native account](screenshots/iphone-account.png) | Successful synthetic signup |
| [Published sample listing](screenshots/iphone-published-listing.png) | Draft resumed and published through the app |
| [Room capture capability](screenshots/iphone-room-capture.png) | Honest unsupported-device state in the simulator |
| [Public web layout](screenshots/web-room-layout.png) | Published synthetic geometry rendered in the browser |
| [Edited native comment](screenshots/iphone-comment-edit.png) | Actual passing expanded interaction at `2a7bf1e`, run38989941387 |
| [Preview privacy page](screenshots/preview-privacy.png) | Actual isolated browser rendering at `c10f520`; synthetic-data notice |
| [Synthetic capture archive](fixtures/synthetic.roomcapture) | Version 1 USTAR/JSON/JPEG input; 30 artificial views; regenerate with `processing/make_synthetic_capture.py` |
| [Trained Gaussian PLY](fixtures/synthetic-tour.ply) | Actual 566-Gaussian Brush output; open with the app viewer or a compatible Gaussian importer |
| [Training result metadata](fixtures/synthetic-tour-result.json) | Training method, view/Gaussian counts and viewer camera for the synthetic run |
| [Synthetic viewer screenshot](screenshots/synthetic-tour-viewer.png) | Actual browser rendering; constant-color fixture, not room-quality evidence |
| [Editable app icon](../../ios/Brand/AppIcon.svg) | Vector source; `ios/Brand/render_icon.py` reproduces the PNG with Pillow |
| [Packaged app icon](../../ios/CuseSublets/Assets.xcassets/AppIcon.appiconset/AppIcon.png) | Opaque 1024px production asset for the development build |
| [Editable room fixture](fixtures/sample-room.json) | Four walls, a door and one furniture box in metres |

To reproduce the web layout, use an isolated development datastore, authenticate as the synthetic listing's owner, add a UUID `id` to the fixture body, POST it to `/api/listings/{id}/scans`, explicitly publish that scan, then open `/#listing/{id}` anonymously. Do not send this fixture to operational data. The editable viewer is `src/RoomScans.tsx`.

CI retains its result bundle and isolated API log as the `iphone-validation` artifact, containing synthetic test data only. Source, Xcode project and fixture are checked in; no signed distribution package is available.

## Operational state

Migration 0012 was applied only to isolated test data. No operational database was migrated or seeded. The hosted preview watches its checkout: it briefly picked up development assets before this was discovered. The canonical checkout was restored to stable main (`2e6d7b4`), rebuilt, and the public site was verified serving its stable bundle (`index-B-K9E7JA.js`). Feature work continues in a separate Git worktree. See the [deployment runbook](../deployment.md).

PR 1 remains draft and unmerged. GitHub reports no protection on main; this record does not claim enforced branch checks. The existing repository is public; its earlier agent instructions incorrectly described it as private. Visibility was not changed during this work.

## Continued marketplace and photographic work — October 16, 2026

Marketplace revision `eb8b6de` passed all ten native unit tests in [run 38986513864](https://github.com/ichen27/cusesublets/actions/runs/38986513864), but its interaction test failed before entering a listing comment. The recording showed the approximate-location map consuming vertical swipes. The follow-up makes the listing-detail map a noninteractive preview and moves the test gesture into the true outer margin. This correction needs a fresh CI pass; the milestone is not marked complete yet.

Photographic tour implementation passed local TypeScript, 47 web/unit tests, two new isolated tour API tests and a signed simulator build-for-testing. The two existing iPhone API tests are also rerun with migration 0013. The transport tests cover checksum failures, owner/guest isolation, concurrent upload/claim, retry fencing, publication, pause/hide revocation and deletion. Native capture policy, recovery-directory isolation and USTAR archive tests are included for CI execution.

A real end-to-end processing run on the isolated API consumed `fixtures/synthetic.roomcapture`, trained 3,000 Brush iterations and produced 566 finite Gaussians. The saved `fixtures/synthetic-tour.ply` and metadata are the actual resulting artifacts. The browser loaded the model, accepted movement/reset controls, and reported zero console errors. `screenshots/synthetic-tour-viewer.png` shows a constant-color synthetic field, not a room. These results prove integration and format compatibility only. See [the processor and capture runbook](photographic-tours.md) for dependencies, recovery, limits and unresolved device quality gates. No operational database or live processor was enabled.

## Authentication and account erasure slice — October 16, evening

Added native/Worker Sign in with Apple, encrypted revocation credentials, verified server notifications and revocation/sign-in race fencing; foreground/local-expiry/401/cold-launch/offline-logout handling; and in-app permanent account deletion with durable storage cleanup and a recoverable private status receipt. See [accounts and deletion](accounts-and-deletion.md) for operator prerequisites and retained-reference/backup limits. Nothing was migrated or enabled in the operational service.

Local evidence: 59 web/domain/SQLite tests, TypeScript, web build, isolated account-erasure API lifecycle, existing scan/mobile-auth/tour runtime checks, and ad-hoc signed simulator build-for-testing pass. New native tests compile; their simulator execution remains pending. Two scoped independent reviews found and resolved cold-launch cache retention, Apple-provider-error expiry bypass, deleted-listing native decoding, logout recovery cleanup and concurrent Apple revocation/session creation.

Run [38988287800](https://github.com/ichen27/cusesublets/actions/runs/38988287800) passed all 13 pre-auth native unit tests. The expanded UI flow reached comment editing, then failed because the test typed at the beginning of the multiline field: its hierarchy showed `Edited synthetic public commentSynthetic public comment`. This proves the edit persisted but the test's backspace replacement assumption was wrong. The test now explicitly inserts an edit prefix. A fresh full run is required; this failed run is not a full interaction pass.

## Release preparation — October 16, late evening

Run [38989941387](https://github.com/ichen27/cusesublets/actions/runs/38989941387) on `2a7bf1e` passed the native unit/interaction suite and isolated scan, tour and account-deletion APIs. It resolves the earlier comment-edit test failure. Both web Checks runs on that revision passed.

Subsequent delivery work adds member blocking/private reports and staff resolution, cached-post hiding, precise-location privacy declarations, shared preview data notice, app icon source, textual room measurements and portable release instructions. Fresh local migrations plus scan/auth (2), tour (2), account deletion (1), and blocking/reporting (1) API tests pass. TypeScript and the signed simulator build-for-testing pass. The new SQLite booking/block race regression passes. Compatible dependency updates bring `npm audit` to zero known findings at validation time. Current full CI, including a new maximum-Dynamic-Type privacy screen interaction, is required before this slice is marked validated.

The native icon's editable SVG/renderer is in `ios/Brand/`; its actual 1024px PNG is in `ios/CuseSublets/Assets.xcassets/AppIcon.appiconset/`. The same preview data notice is bundled in the app and served at `/privacy`. Manual VoiceOver and actual phone validation remain pending. No real iPhone is attached; no distribution archive, provider configuration or operational migration was created.


The final cleanup follow-up limits each account-deletion invocation to eight resource pages with durable checkpoints and a lease. A full sweep beginning after the upload-settling window must complete before the receipt reports success. Regression tests cover progress after failure, late uploads and overlapping schedulers. Local validation now totals **62 web/SQLite tests**, passing TypeScript, web production build/dry-run packaging and all six isolated mobile API tests. Scoped review found no remaining defect in this follow-up. The privacy page was opened in a real browser without console warnings/errors. Final native CI remains the required check on the PR's current revision.


Clean-checkout verification at `c10f520`: cloned the GitHub branch into a new SSD tools directory, ran `npm ci`, TypeScript, all 62 tests, web build, every migration and demo seed. Started the README's exact isolated port8936 quickstart, then passed its documented scan/auth, deletion and blocking tests. The built native app's privacy manifest parses and its bundled notice exactly matches the checked-in JSON. No cloud credentials were required. The simulator build also passes after the cleanup copy change.


Appearance review found fixed light card surfaces would conflict with dark-mode system text. Cards and link accents now resolve for light/dark traits; filled buttons retain a darker orange for white-label contrast. A native regression checks normal-text contrast for both appearances. This improves the implementation but does not replace a manual VoiceOver/full-app accessibility audit. The intermediate `e13385f` native run38991035278 was cancelled when superseded, not counted as a pass.
