# Photographic room tours

The iPhone app captures overlapping, calibrated ARKit camera views. The server stores the capture privately, a separate serial worker trains a Gaussian model, and the owner reviews and explicitly publishes it. Public access also requires a published listing and an active owner. RoomPlan geometry remains a separate feature. Neither output grants a CuseSublets Check.

## Capture and recovery

Photographic capture uses AR world tracking on supported iPhones; LiDAR is not required. The simulator cannot validate capture. Move slowly around one room with good light and overlapping views, including movement sideways. At least 30 stable views are required; aim for 60 or more. Capture stops at three minutes or 180 views. Poorly textured walls, mirrors, motion, occlusions and camera drift can still make reconstruction unusable.

Camera JPEGs, poses and feature points are saved under an owner/listing-specific directory with device file protection and excluded from backup. Each accepted view updates the manifest atomically. An interruption ends the coordinate system; it never silently resumes a new tracking origin. Reopening recovers the saved take. Fewer than 30 views requires a new take. Review source images for personal papers, faces and other private details before upload.

Archives and trained models are limited to 64 MiB. Upload streams from disk and checks size plus SHA-256 on the server. Keep the app open during upload. An interrupted upload retries the whole bounded file with the same capture ID, not individual byte ranges. Retrying cannot create duplicate jobs or replace an already accepted archive. After the server accepts the upload, the app removes its local source copy. Owners can delete server captures and models; downloaded copies cannot be recalled.

## Processor setup

The app and API can run without a processor; the capture screen clearly reports that processing is unavailable. To enable it, apply migrations `0013_room_tours.sql`, `0014_tour_deletions.sql` and `0019_tour_meshes.sql` using the deployment runbook, then configure a private `TOUR_PROCESSOR_TOKEN` of at least 32 random characters both in the Worker and worker environment. Do not commit this value. The processor needs outbound access to the API; no inbound processor endpoint is exposed.

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

### Optional room mesh

With `CUSE_ROOM_MESH=1`, the processor also builds a coloured triangle mesh after Gaussian training (`processing/room_mesh.py`). It needs, in the same Python environment:

- [Depth Anything 3](https://github.com/ByteDance-Seed/Depth-Anything-3), installed from a checkout of commit `3d835ec1a5802d64a8b8b15f817a1ab54809bfe4` with `pip install -e .`. Its code is Apache-2.0.
- The `depth-anything/DA3-BASE` weights, which the upstream model table lists as Apache-2.0. Larger DA3 variants are CC BY-NC 4.0 and must not be substituted for commercial use. Download the weights once and point `CUSE_DA3_MODEL` at the local directory so processing never fetches models at run time.
- Open3D 0.19 and PyTorch 2 with Metal (MPS) or CUDA. The pipeline was validated on an Apple M-series Mac mini with 16 GB of memory.

```sh
export CUSE_ROOM_MESH=1
export CUSE_DA3_MODEL=/absolute/path/to/DA3-BASE
```

The step selects up to 60 evenly spaced views and estimates their depth in one Depth Anything 3 pass, conditioned on the ARKit poses and intrinsics. Processing separate windows of views gave each window its own scale, up to 30% apart, so the view count is capped instead. Pixels below the 40th confidence percentile, outside 0.2–5 m, or across object edges are dropped. The rest is fused into a 2 cm TSDF grid; fragments under 200 triangles are removed and the mesh is simplified to at most 300,000 triangles. It is written as a binary PLY with vertex colours in ARKit world coordinates (metres, +Y up), with metadata for the API. The mesh is uploaded to `/api/tour-processor/{id}/mesh` before completion, under the same claim. Completion keeps only the mesh uploaded by the completing claim, so a mesh from an earlier failed attempt is never shown with a later result. If the mesh step fails or the API rejects the mesh, the tour still completes without one; only the error type is logged.

On the iPhone 17 test scan (91 views), one pass took about 35 s, and the whole job including Gaussian training took 229 s. Measured after simplifying to 35,000 triangles, the mesh's surface roughness fell from 7.2 mm to 4.1 mm compared with fusing the app's single-image depth model. Its share of surface on the six largest planes rose from 19% to 29%. Views six seconds apart agreed within 2.2%, against 17% for the single-image model. Expect holes where no view saw a surface confidently, soft edges, and doubled surfaces if ARKit tracking drifted. It is a reconstruction from photographs, not a measured survey.

Each claim lasts three minutes and is renewed every 45 seconds. Results commit only while the same claim still owns the job. A lost lease stops training; expired jobs can be reclaimed, and three interrupted claims fail visibly until the owner retries. Deleting a job invalidates active workers. Heartbeat, failure and completion writes also recheck owner activity. Use a restart-on-failure service manager for continuous operation. Processing is serial, bounded to 500,000 Gaussians and 3,000 training steps, with a training timeout. This is experimental quality, not a guaranteed photorealistic output.

Working files are private and removed after each completed or failed job. Abrupt machine termination can leave temporary directories; inspect and remove abandoned job directories as part of operating the service. Original captures remain in private object storage until the owner deletes the tour. Opaque deletion IDs are retained in a cleanup ledger; processor polls sweep that ledger so a late upload cannot strand files after a failed cleanup request. A failed sweep keeps its record for retry, and deleted capture IDs cannot be reused. Define a retention policy before a public release.

## Viewing and export

The same lazy-loaded PlayCanvas viewer runs on public listing pages and in an ephemeral, same-origin iPhone web view. Cookies are never placed in URLs. Model requests recheck visibility and account/listing status. Drag to look; use the labeled movement controls or arrow keys, and reset if lost. Movement has no wall collisions. An unsupported graphics device shows an error and offers PLY export.

The exported Gaussian PLY contains Gaussian attributes. A Gaussian-compatible Blender importer is needed; it is not an editable architectural mesh. When processing built a room mesh, **Export room mesh (PLY)** downloads it from `/api/listings/{listing}/tours/{tour}/mesh` with the same visibility rules as the model. It is an ordinary coloured triangle mesh that opens in Blender, MeshLab and most 3D tools. Blender-authored staging should be presented separately and labeled as edited, rather than represented as a capture of the available room.

## Reproducible synthetic validation

[Synthetic capture archive](fixtures/synthetic.roomcapture) contains 30 constant-color 96×64 images and artificial poses/points. [Trained Gaussian PLY](fixtures/synthetic-tour.ply) is actual Brush output from that input, with [result metadata](fixtures/synthetic-tour-result.json) recording display metadata. These are transport and engine compatibility artifacts, **not evidence of real-room visual quality or dimensional accuracy**. Regenerate the archive with:

```sh
python processing/make_synthetic_capture.py docs/mobile/fixtures/synthetic.roomcapture
```

The generator requires Pillow, already included in the capture engine environment. Start the isolated API on port 8936 with the test processor token, then run `tests/tours-runtime.py` as documented in the validation page. Never use tests against operational data. `processing/tour_worker.py --once` handles one queued job with the configured engine. The API tests cover authorization, private/public transitions, visibility revocation, checksum failure, retry, competing uploads/claims and deletion fencing. Real capture/recovery, hosted upload and visual quality remain physical-device release gates.
