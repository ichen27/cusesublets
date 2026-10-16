# iPhone validation — October 16, 2026

This is an initial implementation under validation. A simulator build does not establish device capture quality or App Store readiness.

## Verified

- Web/Worker typecheck, all 45 unit tests and production web build passed locally. The existing large JavaScript bundle warning remains.
- An unsigned iPhone simulator build passed using Xcode 27.1. No signing or global developer-tool configuration was changed.
- Two runtime tests passed against a fresh, isolated local database with migrations and synthetic seed data. They cover room-scan ownership, private upload, explicit publication/hiding, revocation when a listing is paused, unchanged verification fields, malformed input and retry behavior; and mobile-auth verifier binding, one-use codes and logout.
- GitHub [Checks at b1869bc](https://github.com/ichen27/cusesublets/actions/runs/38958860030) passed. The [iPhone workflow](https://github.com/ichen27/cusesublets/actions/runs/38958860150) also passed its build/setup/API-runtime steps; its native test result was pending when this record was first written.
- Standards and spec review findings were corrected; see [review](review.md).

## Unverified and release blockers

- The local simulator test run was interrupted after the mini's internal disk filled during simulator startup. No local native unit/UI test pass is claimed. The app and test targets compiled; a black simulator screenshot is not UI evidence.
- Real LiDAR capture, saved-capture recovery on a physical phone, interruptions/backgrounding, accessibility and room geometry accuracy need device testing.
- Hosted Google/Access authentication, mobile-code expiry and suspended-account native flows are not covered by the two runtime tests.
- Signing team, provisioning, bundle ownership and TestFlight distribution are not configured. No physical iPhone was available for this run.
- Full marketplace parity and photographic/Gaussian reconstruction remain open in the [implementation plan](iphone-plan.md).

## Operational state

Migration 0012 was applied only to isolated test data. No operational database was migrated or seeded. The hosted preview watches its checkout: it briefly picked up development assets before this was discovered. The canonical checkout was restored to stable main (`2e6d7b4`), rebuilt, and the public site was verified serving its stable bundle (`index-B-K9E7JA.js`). Feature work continues in a separate Git worktree. See the [deployment runbook](../deployment.md).

CI retains its result bundle and isolated API log as the `iphone-validation` artifact. Those contain synthetic test data only. No useful simulator screenshots or signed distribution package are available yet.
