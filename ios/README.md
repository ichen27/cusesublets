# CuseSublets for iPhone

Native iPhone client for the existing CuseSublets marketplace, with RoomPlan capture and private-to-public room layouts. This is a development preview with simulator validation, not a released App Store app. See [scope and release boundaries](../docs/mobile/iphone-plan.md).

## Prerequisites and build

Use a Mac with Xcode and an installed iOS simulator runtime. Open `CuseSublets.xcodeproj`, select the CuseSublets scheme and an iPhone simulator, and run. The project is checked in; XcodeGen is only needed when changing `project.yml`.

```sh
xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ios-build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

Run these commands from the repository root. If your active developer tools are the command-line tools, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. No global toolchain changes are required.

For a local camera test using a free Personal Team, select the **Cuse Capture Test** scheme and follow the [iPhone17 installation guide](../docs/mobile/iphone-17-test-guide.md). That scheme opens only the local capture screen, omits the Sign in with Apple entitlement and uses separate app storage. The normal **CuseSublets** scheme retains its entitlement and full authentication requirements. For either physical build, select your own signing team in Xcode and use an available bundle identifier. No team, signing keys or provisioning profiles are committed. RoomPlan layout capture requires a supported LiDAR-equipped device. Photographic capture uses ARKit world tracking and can work on supported non-LiDAR iPhones; both capabilities are checked at runtime. Neither can be validated in a simulator.

## Backend and isolated testing

Release builds use `APIBaseURL` in the project settings. For an isolated simulator runtime, set the Debug scheme environment variable `CUSE_API_URL=http://127.0.0.1:8936`. Only loopback overrides are accepted, and Release builds ignore this variable.

```sh
npm ci
npm run build
npx wrangler d1 migrations apply DB --local --persist-to work/iphone-state
npx wrangler d1 execute DB --local --persist-to work/iphone-state --file seeds/demo.sql
npx wrangler dev --ip 127.0.0.1 --port 8936 \
  --persist-to work/iphone-state --var APP_ENV:development
```

In another terminal:

```sh
API_BASE=http://127.0.0.1:8936 python3 tests/iphone-runtime.py
xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_IPHONE' \
  -derivedDataPath work/ios-build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

Simulator builds and interaction tests use local ad-hoc signing so Keychain session storage has a signed application identity. No Apple signing team or paid membership is needed for this simulator step. An unsigned compile alone cannot verify authentication.

The UI test sets `CUSE_UI_MANUAL_PASSWORD=1` in Debug to type its synthetic password without the system's new-password generator sheet. Normal builds retain new-password AutoFill, and Release ignores this switch. Password-manager interaction needs a separate device check; the automated test exercises manual credential entry.

The UI test creates synthetic accounts, saves/resumes a private draft, and publishes a synthetic listing only on port 8936. Never point tests at operational data. Apply every checked-in migration to fresh isolated state; the native account, room and reporting features need the full schema. Follow the existing deployment runbook before migrating a running datastore; do not seed operational data.

## Try it

1. Browse places and people anonymously; open a listing, profile, map or existing tour.
2. Create a test account or log in. Use You to create/resume a private listing or housing-search draft.
3. Publish a place, add media/check evidence, and open room layouts. Capture is disabled on unsupported hardware.
4. On a supported phone, scan a room, inspect the local result, name it and upload privately. Publish it only after review; check the same listing on the website.
5. Use Matches to start a conversation. Messages, shared documents and negotiation use the existing participant permissions.

## Source and artifacts

- `CuseSublets/`: editable app source.
- `CuseSublets.xcodeproj/`, `project.yml`: build project and its regeneration source.
- `CuseSubletsTests/`, `CuseSubletsUITests/`: native model and interaction checks.
- `../docs/mobile/`: product scope and validation evidence.

Build logs, runtime databases, account cookies and private room captures stay outside Git. Simulator binaries are architecture/runtime-specific and cannot be installed on a physical phone. Distribution packages require signing and should be attached to a versioned release after device validation. No open-source license has been selected for the original project material; public source visibility does not grant redistribution rights. No third-party capture engine is vendored.

## Photographic reconstruction

`PhotoCapture.swift` captures calibrated camera views using ARKit on supported iPhones, including devices without LiDAR. This is separate from RoomPlan layouts. `RoomToursView.swift` manages private source recovery/upload, processing, review, publication and Gaussian PLY export. The viewer uses the same PlayCanvas code as public web pages, with an ephemeral same-origin cookie store. See [photographic tours](../docs/mobile/photographic-tours.md) for the separate processor setup and current validation limits. All migrations are required; photographic capture reports unavailable until a processor secret is configured.

## Accounts and release preparation

Apple sign-in, Google authorization, device-only Keychain sessions, expiry/revocation checks and in-app account deletion share the existing backend. See [account setup and deletion](../docs/mobile/accounts-and-deletion.md). Release Google login is hidden unless equivalent Apple authentication is configured. Hosted flows still need provider/device validation.

You includes blocked members, private reporting, the bundled data notice and deletion status after sign-out. The same data notice is available at `/privacy` on the web. It describes the synthetic-data preview and is not a substitute for an operator-approved production privacy policy.

The app icon is in `Assets.xcassets`, with editable source and a renderer in `Brand/`. `PrivacyInfo.xcprivacy` declares collected data, including home pin coordinates and room/environment scanning; verify the final archive and provider behavior before submitting App Store privacy answers. Camera permission text is included. No signing team or secrets are stored in the project.

Follow [release preparation and physical test matrix](../docs/mobile/release-checklist.md) for build configuration, archive commands and remaining device evidence.

For an iPhone 17, start with the [physical test guide](../docs/mobile/iphone-17-test-guide.md). Debug builds include **You → Device capture check**, which captures and exports locally without a backend or account. Release builds omit this screen. Full upload, reconstruction and account testing still require the designated staging rollout.
