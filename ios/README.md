# CuseSublets for iPhone

Native iPhone client for the existing CuseSublets marketplace, with RoomPlan capture and private-to-public room layouts. This is an initial implementation under validation, not a released App Store app. See [scope and release boundaries](../docs/mobile/iphone-plan.md).

## Prerequisites and build

Use a Mac with Xcode and an installed iOS simulator runtime. Open `CuseSublets.xcodeproj`, select the CuseSublets scheme and an iPhone simulator, and run. The project is checked in; XcodeGen is only needed when changing `project.yml`.

```sh
xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ios-build CODE_SIGNING_ALLOWED=NO build
```

Run these commands from the repository root. If your active developer tools are the command-line tools, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. No global toolchain changes are required.

For a physical iPhone, select your own signing team in Xcode and use an available bundle identifier. No team, signing keys or provisioning profiles are committed. Camera capture requires a supported LiDAR-equipped device; other iPhones can browse and manage the marketplace.

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

Simulator interaction tests use local ad-hoc signing so Keychain session storage has a signed application identity. No Apple signing team or paid membership is needed for this simulator step. An unsigned compile alone cannot verify authentication.

The UI test sets `CUSE_UI_MANUAL_PASSWORD=1` in Debug to type its synthetic password without the system's new-password generator sheet. Normal builds retain new-password AutoFill, and Release ignores this switch. Password-manager interaction needs a separate device check; the automated test exercises manual credential entry.

The UI test creates synthetic accounts, saves/resumes a private draft, and publishes a synthetic listing only on port 8936. Never point tests at operational data. Schema migration 0012 is required for room layouts and native Google sign-in. Follow the existing deployment runbook before migrating a running datastore; do not seed operational data.

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

Build logs, runtime databases, account cookies and private room captures stay outside Git. Simulator binaries are architecture/runtime-specific and cannot be installed on a physical phone. Distribution packages require signing and should be attached to a versioned release after device validation. Existing repository licensing applies; no new third-party code is vendored.
