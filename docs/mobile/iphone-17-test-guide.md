# iPhone 17 device test

This guide separates a local camera test from the complete marketplace test. Neither a simulator pass nor a successful camera capture establishes reconstruction quality.

## Your device

The regular iPhone 17 has no LiDAR scanner ([Apple specifications](https://www.apple.com/iphone-17/specs/)). Test ARKit photographic capture and Gaussian tours on it. The RoomPlan layout feature should report unavailable; a LiDAR-equipped supported device is needed to validate measured room layouts.

## Install with your personal Apple ID

A paid membership is not needed for this local camera test. Apple supports Personal Team installation from Xcode; profiles expire after seven days, requiring a rebuild/reinstall. TestFlight and full provider testing remain separate paid-team work. See [Apple's account and Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account).

1. On your MacBook, download the [feature branch ZIP](https://github.com/ichen27/cusesublets/archive/refs/heads/feat/iphone-app.zip) and unzip it, or clone `feat/iphone-app`. Open `ios/CuseSublets.xcodeproj`; no XcodeGen installation is needed.
2. In **Xcode → Settings → Apple Accounts**, add your personal Apple Account. Select the **Cuse Capture Test** scheme in the toolbar. Its Run configuration is **PersonalDevice**.
3. Select the **CuseSublets app target → Signing & Capabilities**, enable automatic signing and select your **Personal Team** for the PersonalDevice configuration. If Xcode says the bundle identifier is unavailable, change that configuration's identifier to your own unique value, such as `com.yourname.cusesublets.capturetest`. Keep team/identifier changes local.
4. Connect your iPhone17 to the MacBook and trust the connection. Select the attached phone as the run destination. Enable **Settings → Privacy & Security → Developer Mode** on the phone when requested, following the restart/confirmation prompts.
5. Click **Run**. Xcode creates the development signing assets and installs **Cuse Capture Test**. If the phone asks to trust your developer identity, follow its Settings prompt.
6. The app opens directly into **Device capture check**. It has no marketplace login or background session requests and does not need a backend. Follow the capture steps below.

The PersonalDevice configuration has no Sign in with Apple entitlement and uses a separate app identifier/storage container. If you see an unsupported Sign in with Apple provisioning error, verify you selected **Cuse Capture Test** and its **PersonalDevice** Run configuration. Do not remove the normal app's entitlement to make the error disappear.

The standard **CuseSublets** scheme retains full marketplace behavior and its original signing requirements. Its Debug build exposes the same check through **You → Device capture check**. PersonalDevice is for Run/local capture only; do not use Archive or TestFlight for this test. The scheme's Archive action uses the standard Release configuration, which still needs the full team's signing setup.

No signed phone package or physical installation is claimed by repository build checks. Use the same identifier when reinstalling, and export important takes privately before reinstalling or deleting the app. A simulator binary cannot be installed on the phone. The [distribution checklist](release-checklist.md) remains applicable to TestFlight and release work.

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
