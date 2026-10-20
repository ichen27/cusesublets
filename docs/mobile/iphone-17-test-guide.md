# iPhone 17 device test

This guide separates a local camera test from the complete marketplace test. Neither a simulator pass nor a successful camera capture establishes reconstruction quality.

## Your device

The regular iPhone 17 has no LiDAR scanner ([Apple specifications](https://www.apple.com/iphone-17/specs/)). Test ARKit photographic capture and Gaussian tours on it. The RoomPlan layout feature should report unavailable; a LiDAR-equipped supported device is needed to validate measured room layouts.

## Install a development build

1. On the Mac running Xcode, check out `feat/iphone-app` from this repository and open `ios/CuseSublets.xcodeproj`. Use the checked-in project.
2. Connect and trust the iPhone. Enable Developer Mode on the phone if Xcode requests it.
3. In the app target's Signing & Capabilities, select your Apple development team and an available bundle identifier. Keep these personal settings out of commits. The existing Sign in with Apple entitlement needs a team/provisioning profile supporting that capability; do not claim provider testing passed by removing it.
4. Select **Debug**, the attached iPhone, and Run. This requires device signing; the simulator app cannot be installed on a phone. No signed phone package or TestFlight upload is provided yet.
5. Open **You → Device capture check**. This screen is compiled only into Debug builds and works without signing into the marketplace. If an unrelated session error appears, dismiss it and open You.

If installing through TestFlight instead, complete the [distribution checklist](release-checklist.md). Release builds omit the local capture-check screen.

## Local photographic test — no backend required

Record the build commit, iOS version, date, room lighting and result of each step. Use an empty room you have permission to capture. Avoid personal papers, faces and mirrors reflecting private content.

1. Confirm photographic capture is available and LiDAR layouts are unavailable.
2. Tap **Start camera test**. On a fresh installation, allow camera access. If the permission prompt interrupts the start, tap **Start capture** once the app is active.
3. Walk slowly around the room, keeping adjacent views overlapping. Move sideways as well as rotating. Aim for at least 60 stable views; the minimum is 30. Finish capture and return to the local test screen.
4. Force-close and reopen the app. The local take should still be recoverable.
5. Tap **Prepare private capture archive**, then **Export private capture archive**. Save it in a private location or transfer it directly to your Mac. It contains actual room photographs and camera metadata; never attach it to the public GitHub PR.
6. Discard the local take, reopen the app, and confirm it is gone. Exported copies must be deleted separately.
7. Repeat with camera permission denied, then restored in Settings. Repeat with the app backgrounded or the phone locked during capture. An interrupted take must stop; it must not silently combine a new camera coordinate system with the old one. Takes with fewer than 30 views should fail export with a clear message.

The archive is reconstruction input, not a finished Gaussian model. It can be evaluated with the pinned capture engine described in [photographic tours](photographic-tours.md). Inspect the resulting model and exported PLY before making quality claims.

## Full marketplace and upload test — staging required

The default hosted preview has not received this mobile branch's migrations or processor rollout. Do not treat that older service as a validated mobile backend.

Before testing the complete flow, an operator must prepare a designated HTTPS staging backend with all migrations, private storage, a serial reconstruction processor and deletion cleanup scheduling. Configure `INFOPLIST_KEY_APIBaseURL` for that staging origin when building. `127.0.0.1` on a phone is the phone itself; the simulator's loopback override does not connect it to the Mac.

Use synthetic account/listing details. Then test:

- Signup/login, private listing save/reopen, publication and search editing.
- Capture → private upload → processing → private viewing → explicit publication → hide/delete.
- Network loss during upload, retry, relaunch and account switching.
- Account deletion, lost response/relaunch recovery, and two accounts' independent deletion receipts.
- VoiceOver, large text, dark mode and camera controls.
- Apple/Google hosted sign-in only after their actual provider configuration is complete.

Keep the test listing and room data private until explicitly choosing to publish. The full [release matrix](release-checklist.md) remains authoritative.

## Evidence to return

Send the build commit, iOS version, pass/fail for each step, and the exact error plus reproduction steps for failures. Screenshots should omit private account/room data. Keep raw archives private; arrange a private transfer for reconstruction analysis.
