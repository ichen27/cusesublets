# CuseSublets

An iPhone-first sublease marketplace for Syracuse, with public web browsing and a web staff workspace. Members can publish places and housing searches, find compatible stays, discuss posts, negotiate in private conversations, and share room layouts or photographic tours.

**Status:** working development preview, not an App Store release or a live payment service. Native simulator flows and synthetic reconstruction are tested; real-room quality, physical-device recovery, hosted authorization and distribution remain release gates. See [the mobile plan](docs/mobile/iphone-plan.md), [validation evidence](docs/mobile/validation.md) and [release checklist](docs/mobile/release-checklist.md).

## Local quickstart

Prerequisites: Node.js 22+, npm and Python 3 for API checks. Native development additionally needs macOS, Xcode and an iOS simulator. No Cloudflare account is needed for the isolated local demo.

```sh
git clone https://github.com/ichen27/cusesublets.git
cd cusesublets
# Until the mobile PR is merged:
git switch feat/iphone-app
npm ci
npm run build
npx wrangler d1 migrations apply DB --local --persist-to work/demo-state
npx wrangler d1 execute DB --local --persist-to work/demo-state --file seeds/demo.sql
npx wrangler dev --ip 127.0.0.1 --port 8936 \
  --persist-to work/demo-state --var APP_ENV:development
```

Open <http://127.0.0.1:8936>. Use **Log in / Switch demo role** for renter, host or admin. Demo identities require both development mode and a loopback request hostname. Seeds contain synthetic homes and externally hosted illustrative photos; no real housing offer is created. Keep one runtime per persistence directory and never seed operational data. `work/`, dependencies, private uploads and credentials are excluded from Git.

For the iPhone client, follow [ios/README.md](ios/README.md), using the same local API. Release builds ignore local URL overrides. The checked-in project needs no project generator to build.

## Try the marketplace

1. Browse places and people, filter dates/budget/amenities and map areas, or save a post.
2. Sign up with a synthetic account. Save and resume a private listing or search draft, then publish it explicitly.
3. Choose your activity in Matches; contact a compatible member. Messages, shared documents, offers, counteroffers and reservations use participant permissions.
4. Add listing media and private review evidence. Check badges remain separate from publication and never guarantee identity, safety or permission to sublet.
5. On supported physical hardware, capture an approximate RoomPlan layout or an ARKit photographic dataset. Review privately before publishing. Photographic training requires a separately configured processor; it is not enabled by the quickstart.
6. Report inappropriate posts or members, block contact, and review reports in the staff workspace. Existing reservation history remains accessible. Account deletion removes personal content and provides a recoverable status receipt.

Local demo signing and payment are simulations only. Production endpoints fail closed: no money, escrow, legal signature, transfer or refund is created.

## Architecture and deliverables

- `ios/`: SwiftUI iPhone app, MapKit, RoomPlan, ARKit capture, native tests, editable app icon and Xcode project.
- `src/`: React web marketplace, staff review tools and lazy-loaded PlayCanvas Gaussian viewer.
- `worker/`, `migrations/`, `shared/`: Worker API, D1 schema, R2 storage integration and shared policy/data definitions.
- `processing/`: private reconstruction job runner; see [processor setup and pinned engine access](docs/mobile/photographic-tours.md).
- [Artifact index and screenshots](docs/mobile/validation.md#artifacts): native interaction evidence, editable room fixture, actual synthetic capture archive and trained Gaussian PLY output. Synthetic training proves compatibility, not room quality.
- [Accounts/deletion](docs/mobile/accounts-and-deletion.md), [API contract](docs/API.md), [deployment runbook](docs/deployment.md): behavior and operator prerequisites.

RoomPlan geometry and Gaussian appearance models serve different purposes. PLY export requires a compatible Gaussian importer for Blender; it is not an editable architectural wall mesh. Captures can contain private details and are never automatically published.

## Validation

```sh
npm run typecheck
npm test
npm run build
npm run deploy:check # validates packaging; does not deploy
# Against the isolated quickstart runtime only:
API_BASE=http://127.0.0.1:8936 python3 tests/iphone-runtime.py
API_BASE=http://127.0.0.1:8936 python3 tests/account-deletion-runtime.py
API_BASE=http://127.0.0.1:8936 python3 tests/member-blocks-runtime.py
```

The [iPhone workflow](.github/workflows/iphone.yml) creates fresh local state, tests scan/auth/tour/deletion/blocking APIs, and runs native units and interaction tests. The web workflow runs type checks, units and a production build. Browser engine chunks remain large; photographic playback is loaded separately. Simulator success does not establish camera quality or VoiceOver usability.

## Release limits

Before accepting real customer data: configure and test hosted Apple/Google authorization, deletion scheduling and backup handling, private support contact and privacy/retention terms; validate physical capture and accessibility; obtain signing/provisioning and complete TestFlight review. The local watched preview does not automatically execute cloud Cron Triggers. See the release checklist for concrete evidence required.

Verified email/password recovery, push notifications, a legal-signing provider and real payments are not configured. Android is deferred. The photographic processor depends on a separate private research repository; the app reports unavailable until configured. No distribution-signed phone package is included.

## Contribution and licensing

Use focused branches and pull requests; run applicable checks and preserve existing data. See [CONTRIBUTING.md](CONTRIBUTING.md). This existing repository is public. No open-source license has been selected for the original project code/artifacts; public visibility does not grant redistribution rights. Resolve licensing before distributing a release. Dependencies retain their own licenses; no third-party reconstruction engine is vendored.
