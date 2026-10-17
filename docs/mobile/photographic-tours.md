# Photographic room tours

The iPhone app captures overlapping, calibrated ARKit camera views. The server stores the capture privately, a separate serial worker trains a Gaussian model, and the owner reviews and explicitly publishes it. Public access also requires a published listing and an active owner. RoomPlan geometry remains a separate feature. Neither output grants a CuseSublets Check.

## Capture and recovery

Photographic capture uses AR world tracking on supported iPhones; LiDAR is not required. The simulator cannot validate capture. Move slowly around one room with good light and overlapping views, including movement sideways. At least 30 stable views are required; aim for 60 or more. Capture stops at three minutes or 180 views. Poorly textured walls, mirrors, motion, occlusions and camera drift can still make reconstruction unusable.

Camera JPEGs, poses and feature points are saved under an owner/listing-specific directory with device file protection and excluded from backup. Each accepted view updates the manifest atomically. An interruption ends the coordinate system; it never silently resumes a new tracking origin. Reopening recovers the saved take. Fewer than 30 views requires a new take. Review source images for personal papers, faces and other private details before upload.

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

`fixtures/synthetic.roomcapture` contains 30 constant-color 96×64 images and artificial poses/points. `fixtures/synthetic-tour.ply` is actual Brush output from that input, with `fixtures/synthetic-tour-result.json` recording display metadata. These are transport and engine compatibility artifacts, **not evidence of real-room visual quality or dimensional accuracy**. Regenerate the archive with:

```sh
python processing/make_synthetic_capture.py docs/mobile/fixtures/synthetic.roomcapture
```

The generator requires Pillow, already included in the capture engine environment. Start the isolated API on port 8936 with the test processor token, then run `tests/tours-runtime.py` as documented in the validation page. Never use tests against operational data. `processing/tour_worker.py --once` handles one queued job with the configured engine. The API tests cover authorization, private/public transitions, visibility revocation, checksum failure, retry, competing uploads/claims and deletion fencing. Real capture/recovery, hosted upload and visual quality remain physical-device release gates.
