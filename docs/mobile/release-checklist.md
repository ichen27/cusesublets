# iPhone release checklist

This is a development-preview release worksheet. Empty evidence cells mean unverified, not passed. Simulator CI, synthetic reconstruction and the signed simulator build do not establish real-room accuracy or authorize accepting customer data.

## Configuration and signing

1. Confirm the owner's Apple Developer Program team, registered bundle ID and physical iPhone. No physical phone is currently connected; no team is configured in source.
2. In `ios/project.yml`, set the owned app bundle identifier and production `INFOPLIST_KEY_APIBaseURL`; regenerate with XcodeGen when changing project structure. Keep secrets out of the app and repository. Test-target identifiers must also be compatible with the selected team.
3. Configure Sign in with Apple for that identifier and the matching server client ID, keys and notification URL. Configure the Access mobile redirect for Google. Follow [accounts/deletion](accounts-and-deletion.md); do not show a working provider unless its complete hosted flow passes.
4. In Xcode, select the team, an attached registered device and automatic signing. Verify camera permission, correct API origin and provider entitlements on the phone.
5. After the device matrix passes, increment the build number and archive the Release scheme. One CLI equivalent, from the repository root, is:

```sh
xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath work/CuseSublets.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID archive
```

The placeholder is intentionally not a working signing identity. Archive requires configured certificates/profiles. Open the archive in Xcode Organizer, validate it, inspect its privacy report and distribute to App Store Connect/TestFlight using the owner's account. Export options vary with signing method; use the installed `xcodebuild -help` or Xcode-generated export settings. No upload has been performed.

References: [Apple distribution preparation](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases). Team/bundle ownership and App Store Connect records cannot be inferred from a successful simulator build.

## Device evidence matrix

Record device model, iOS version, app commit/build, backend revision, date and tester with each result. Use an authorized test room without personal documents or bystanders; remove private raw capture data after evaluation. Record consent before sharing any actual-property artifacts.

| Test | Required observation | Evidence |
| --- | --- | --- |
| LiDAR RoomPlan | Complete the same room twice; compare at least three independently measured dimensions; record absolute and percentage errors, missing walls and furniture mistakes. Keep outputs labelled approximate. | Pending |
| Non-LiDAR phone | RoomPlan explains unavailability; ARKit photographic capability is evaluated independently; marketplace remains usable. | Pending |
| Camera permission | Deny, restore permission in Settings, return to app; no false capture completion. | Pending |
| Interruption | Background/lock, incoming interruption and session tracking loss end or preserve capture coherently; no mixed coordinate origins. | Pending |
| Recovery | Relaunch after capture and after upload failure; owner sees private recovery; another account cannot access it. | Pending |
| Upload failure | Disable network, retry, interrupt response, verify one job/layout and no automatic publication. | Pending |
| Photographic quality | Train a real room; inspect held-out views, thin objects, mirrors, windows, textureless walls and traversal; record artifacts and limits. | Pending |
| Export | Open exported PLY with a compatible Gaussian importer in Blender; verify scale/orientation and document importer/version. | Pending |
| Resource limits | Long capture, storage pressure and older supported phone; bounded files and clear recoverable errors. | Pending |
| Hosted auth | Apple first/repeat/private-email login, cancellation, credential revocation and notifications; Google callback; expiry and suspension. | Pending |
| Account deletion | Request, lose response, relaunch signed out, recover receipt; verify storage/provider cleanup plus backup handling on deployed infrastructure. | Pending |
| Accessibility | VoiceOver navigation/focus for tabs, maps' list alternatives, forms, errors, capture and textual measurements; maximum Dynamic Type, Increase Contrast and Reduce Motion. | Pending |
| Safety | Block from profile/thread, navigate back through saved posts/searches, confirm new contact fails; report visible only to staff. | API passed; device pending |
| Distribution | Install the actual TestFlight build, repeat login/capture/deletion against designated staging; no Debug overrides. | Pending |

Do not choose a universal scan-accuracy promise from a single room. Agree on the product tolerance after representative evidence; never present generated appearance or inferred walls as survey-grade measurements.

## Backend and operational gates

- Apply **all** migrations in a staged rollout with backup/recovery verification. Do not seed production. Keep the stable watched checkout untouched until the rollout is reviewed.
- Configure D1/R2, exact origin, Apple credentials, Google Access configuration and the separate serial reconstruction worker. The processor's private pinned engine must be accessible to its operator.
- Prove scheduled deletion cleanup runs. `wrangler dev` serving a local tunnel does not automatically run the deployed cloud cron; supply and monitor an equivalent scheduler before exposing account deletion to real users.
- Finalize backup expiry and a deletion-ledger replay procedure before restoring backups; active-storage completion does not erase old backups. Do not claim legally required retention without reviewing the actual obligations.
- Replace the preview data notice with an operator-approved production policy and a private support contact. Verify App Store privacy answers against the archive and provider behavior, including precise home pins, user content and environment scanning. The notice currently prohibits real customer data in this preview.
- Staff must actually monitor abuse reports, moderate content and respond through an operational support process. Interface controls alone do not provide moderation coverage.
- Keep real payments/legal signing disabled until real provider integrations and their dispute/refund/contract policies are ready. Email verification/recovery and push notifications are not configured.
- Confirm rights/licensing for original source/artifacts and any distributed dependencies before distributing the release. Public repository visibility is not a license grant.

## Handoff evidence

Attach current CI links, reviewed diff, actual screenshots, completed device results and the validated archive/TestFlight build number. Include production migration/backup verification separately. This worksheet is prepared; its pending steps have not been performed.
