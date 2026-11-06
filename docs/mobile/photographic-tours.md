# Photographic room tours

The iPhone app captures overlapping, calibrated ARKit camera views. The server stores the capture privately, a separate serial worker trains a Gaussian model, and the owner reviews and explicitly publishes it. Public access also requires a published listing and an active owner. RoomPlan geometry remains a separate feature. Neither output grants a CuseSublets Check.

## Capture and recovery

Photographic capture uses AR world tracking on supported iPhones; LiDAR is not required. The simulator cannot validate capture. Move slowly around one room with good light and overlapping views, stepping sideways between views. At least 30 stable views are required; aim for 60 or more. Capture stops at three minutes or 180 views, the limits of the processing engine.

The app chooses views silently: it saves a camera frame only when it is likely to help reconstruction (`PhotoCapturePolicy.swift`):

- **Sharp.** The expected smear from camera motion during the exposure, `(turn rate + speed / distance) × exposure × focal length`, must stay under 4 pixels. Dim rooms need slower movement.
- **Parallax.** A new view needs a sideways step of about 6% of the distance to the room (6–20 cm). Turning in place counts as a new view only twice in a row, because rotation alone gives reconstruction no depth.
- **Trackable.** At least 40 tracked features in view.
- At least 0.4 s apart, under 0.6 m/s and 0.9 rad/s, with normal tracking and enough light.

Views keep the camera's full 1920 × 1440 resolution. JPEG quality adapts to the 64 MiB upload limit: each view gets an equal share of the remaining space after reserving manifest space for every view still possible, so a busy room gets lower quality instead of a take refused at the end. Encoding and file writes run off the camera thread. Poorly textured walls, mirrors, occlusions and camera drift can still make reconstruction unusable.

Camera JPEGs, poses and feature points are saved under an owner/listing-specific directory with device file protection and excluded from backup. Each view's image is written before its record is appended to `frames.jsonl`; recovery keeps the complete views up to the first incomplete one, and packaging builds `manifest.json` from them. Takes saved by earlier builds, which have only `manifest.json`, still package. An interruption ends the coordinate system; it never silently resumes a new tracking origin. Reopening recovers the saved take. Fewer than 30 views requires a new take. Review source images for personal papers, faces and other private details before upload.

### Coverage overlay

While capturing, the camera view shows which surfaces have been captured well enough for reconstruction. Unseen areas have a blue tint. Seen surfaces appear as small squares: amber when seen from one direction, light yellow from two, and nearly clear once seen from three directions at least 15° apart. A caption reports the covered share of seen surfaces as text, so the overlay does not rely on colour alone.

The overlay works without LiDAR. A bundled Core ML model ([Depth Anything V2 Small](../../THIRD_PARTY_NOTICES.md)) estimates relative depth from camera frames: every saved view, plus sharp, tracked frames at most four times a second, so the overlay fills in as the camera sweeps instead of only when a view is saved. Frames rejected for motion, blur or too few features do not paint. ARKit's tracked feature points convert it to metres by fitting inverse depth `1/z ≈ a·p + b`, and the result is added to a 10 cm voxel map. Views whose tracked points cannot fit the depth map are skipped for the overlay but still saved. The model runs on a background queue; a frame arriving while the previous estimate is still running is not added to the overlay. Because covering a surface from three directions requires moving between positions, the views saved along the way normally cover it too; surfaces seen only while turning in place stay amber.

Depth maps and the coverage map stay in memory and are not written to the take or uploaded. Limits: depth from one image is approximate, so the overlay is guidance, not a measurement. Mirrors, glass and blank walls with few tracked points may stay blue or show stray squares. The map is not saved, so a recovered take shows no overlay.

### Guidance

Normal capture shows no changing instructions; the overlay is the guidance. A short hint appears over the camera only when a problem lasts: 0.6 s for moving too fast, blur, lost tracking, low light or a view with too few features, and 1.5 s for turning in place without stepping sideways. A hint stays up 0.6 s after the problem clears, so it does not flicker.

### Camera stream recording (development only)

The development-only **Device capture check** screen also records a camera stream alongside the take (`CaptureStream.swift`). Marketplace captures never record one. Every 0.2 s it saves a 640 × 480 JPEG with that frame's calibration, pose, tracking state, shutter time, light estimate and up to 300 tracked points. It also saves what the view rules decided for that frame: the reason it was saved or skipped (for example `blurred`, `fewFeatures` or `noNewViewpoint`), the measured speed, turn rate, distance and predicted blur, and any hint shown. `summary.json` totals the seconds spent in each reason over every camera frame and lists the thresholds in force.

The frame is shrunk on the camera thread so ARKit's buffer is released at once; encoding and writing run on a background queue, and a frame due while the previous one is still being written is dropped and counted. Recording stops at 200 MB while capture continues; a three-minute take is typically 40–50 MB. **Prepare camera stream recording** packages it as `room.roomstream`, an uncompressed USTAR archive of `summary.json`, `stream.jsonl` and `frames/NNNNN.jpg`. It is not a capture archive and cannot be uploaded for processing. It contains room photographs: keep it private, and discard the take to delete the local copy.

Archives and trained models are limited to 64 MiB. Upload streams from disk and checks size plus SHA-256 on the server. Keep the app open during upload. An interrupted upload retries the whole bounded file with the same capture ID, not individual byte ranges. Retrying cannot create duplicate jobs or replace an already accepted archive. After the server accepts the upload, the app removes its local source copy. Owners can delete server captures and models; downloaded copies cannot be recalled.

## Processor setup

The app and API can run without a processor; the capture screen clearly reports that processing is unavailable. To enable it, apply migrations `0013_room_tours.sql` and `0014_tour_deletions.sql` using the deployment runbook, then configure a private `TOUR_PROCESSOR_TOKEN` of at least 32 random characters both in the Worker and worker environment. Do not commit this value. The processor needs outbound access to the API; no inbound processor endpoint is exposed.

The adapter reuses the existing [apartment-3d-lab capture engine](https://github.com/ichen27/apartment-3d-lab/tree/b1099a13eb8a6874f91ec92a63b9a2f444a31c2b), pinned to that revision. Clone it into a separate dependency directory, check out that commit, create a Python environment, and install its `requirements-capture.txt`. This dependency's repository access is required; it is not bundled with the marketplace. Install a compatible Brush 0.3 Apple Silicon CLI separately. Preserve its upstream license and obtain the binary from its upstream release. No research-room datasets or customer photographs are distributed here.

Set these environment variables using your service manager or private environment file:

```sh
export CUSE_PROCESSOR_API=https://YOUR_APP_HOST
export TOUR_PROCESSOR_TOKEN=YOUR_PRIVATE_PROCESSOR_SECRET
export CUSE_CAPTURE_ENGINE=/absolute/path/to/pinned/apartment-3d-lab
export CUSE_BRUSH=/absolute/path/to/brush_app
export CUSE_PROCESSOR_WORK=/absolute/path/to/private/temporary/jobs
python processing/tour_worker.py
```

Use the Python interpreter from the capture engine's environment. The placeholder secret above must be replaced, not used literally. `CUSE_PROCESSOR_ORIGIN` can separately supply the configured Worker Origin when a local reverse proxy rewrites it; normally it equals the HTTPS API origin. Only HTTPS or explicit loopback HTTP is accepted, and authenticated redirects are refused.

Each claim lasts three minutes and is renewed every 45 seconds. Results commit only while the same claim still owns the job. A lost lease stops training; expired jobs can be reclaimed, and three interrupted claims fail visibly until the owner retries. Deleting a job invalidates active workers. Heartbeat, failure and completion writes also recheck owner activity. Use a restart-on-failure service manager for continuous operation. Processing is serial, bounded to 500,000 Gaussians and 3,000 training steps, with a training timeout. This is experimental quality, not a guaranteed photorealistic output.

Working files are private and removed after each completed or failed job. Abrupt machine termination can leave temporary directories; inspect and remove abandoned job directories as part of operating the service. Original captures remain in private object storage until the owner deletes the tour. Opaque deletion IDs are retained in a cleanup ledger; processor polls sweep that ledger so a late upload cannot strand files after a failed cleanup request. A failed sweep keeps its record for retry, and deleted capture IDs cannot be reused. Define a retention policy before a public release.

## Viewing and export

The same lazy-loaded PlayCanvas viewer runs on public listing pages and in an ephemeral, same-origin iPhone web view. Cookies are never placed in URLs. Model requests recheck visibility and account/listing status. Drag to look; use the labeled movement controls or arrow keys, and reset if lost. Movement has no wall collisions. An unsupported graphics device shows an error and offers PLY export.

The exported PLY contains Gaussian attributes. A Gaussian-compatible Blender importer is needed; it is not an editable architectural mesh. Blender-authored staging should be presented separately and labeled as edited, rather than represented as a capture of the available room.

## Reproducible synthetic validation

[Synthetic capture archive](fixtures/synthetic.roomcapture) contains 30 constant-color 96×64 images and artificial poses/points. [Trained Gaussian PLY](fixtures/synthetic-tour.ply) is actual Brush output from that input, with [result metadata](fixtures/synthetic-tour-result.json) recording display metadata. These are transport and engine compatibility artifacts, **not evidence of real-room visual quality or dimensional accuracy**. Regenerate the archive with:

```sh
python processing/make_synthetic_capture.py docs/mobile/fixtures/synthetic.roomcapture
```

The generator requires Pillow, already included in the capture engine environment. Start the isolated API on port 8936 with the test processor token, then run `tests/tours-runtime.py` as documented in the validation page. Never use tests against operational data. `processing/tour_worker.py --once` handles one queued job with the configured engine. The API tests cover authorization, private/public transitions, visibility revocation, checksum failure, retry, competing uploads/claims and deletion fencing. Real capture/recovery, hosted upload and visual quality remain physical-device release gates.
