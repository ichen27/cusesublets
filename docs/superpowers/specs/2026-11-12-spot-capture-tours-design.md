# Spot-capture 360° tours: design

Status: draft for owner approval, 2026-11-12.
Branch: `feat/spot-tours` (started from `feat/capture-quality`).

## Why

A sublessor uses the CuseSublets iPhone app to capture their apartment so prospective subtenants, browsing in the same app, can judge it without a visit.

Today's capture tries to reconstruct the whole room: you walk around stepping sideways, and the app builds a Gaussian splat (plus, on `feat/room-mesh`, a coloured mesh) that viewers can move through freely. That needs good coverage of everything from every angle. Ordinary users don't get it, and wherever coverage was thin the free-roam model looks blurry.

The new model follows Matterport's phone capture and Google Street View's viewing. The sublessor stands at a few spots and turns in place under guidance. Each spot becomes a clean, stitched 360° photo. Viewers only ever stand at those spots and jump between them by tapping circles on the floor. The rough 3D model still gets built, but it is only scaffolding: it places the spots, powers an overview, and smooths the jump. It is no longer the main thing anyone looks at.

## Who and what success looks like

- **Sublessor (capturing):** a non-expert with an iPhone, no LiDAR assumed (the test device is a regular iPhone 17). Success: they finish a typical bedroom (4–6 spots) on their first try with no instructions beyond what's on screen, and every spot's 360 looks clean.
- **Prospective subtenant (viewing, in the app):** success is that it feels like Street View. They drag to look around, tap a floor circle to move, and always know where they are.

## Goals

1. Guided per-spot capture: a turn-in-place flow with dots to line up, a fill-in progress for each dot, and an overall progress for the spot.
2. A top-down capture map between spots showing numbered spots, the captured area, and a room-coverage percentage.
3. A stitched 360° panorama per spot, with no black holes at the ceiling or floor.
4. An in-app viewer: Street View-style looking at a spot, floor circles to move between spots, and an overview to jump to any spot.
5. A rough 3D model built from all captured frames, used for spot placement, the overview, and transitions.

## Non-goals

- Free-roam movement through the model at arbitrary positions. This replaces the current walk-anywhere viewer for these tours.
- Measurements, floor plans with dimensions, multiple floors, or whole-building tours. A tour covers one apartment's rooms on one level.
- LiDAR-specific paths. They may come later, but the design must work without LiDAR.
- Editing panoramas, virtual staging, or hotspots and annotations.
- Capturing from the web.

## Anti-goals (would count as failure even if it technically works)

- Panoramas with visible black regions, smeared seams through the middle of the frame, or obvious exposure banding between slices.
- Floor circles that put the viewer somewhere other than where the circle appeared, or that visibly float off the floor.
- A capture flow that loses every completed spot because of one interruption.
- A coverage percentage that confidently reads high while large parts of the room were never seen.
- Guidance that nags. Hints appear only for lasting problems, as in the current capture (see `docs/mobile/photographic-tours.md`, "Guidance").

## Decided with the owner

### Capture flow

1. **Start a spot.** On the capture map, tap the shutter. The camera view opens with a fixed circle (the reticle) in the centre and the next target dot on screen. A short caption says what to do ("Point the camera at the dot"), and a dotted line points to off-screen dots.
2. **Turn.** The sublessor stands still and turns to line the reticle up with each dot. While aligned, a progress fill sweeps around the circle. When it completes, that slice is captured and the next dot appears. **Undo** removes the last captured slice. An overall progress for the spot shows how much of the full sphere is done.
3. **Back to the map.** When a spot is complete, the app returns to a top-down 3D view of everything captured so far, like Matterport's: the room's point cloud or mesh seen from above, numbered spot markers, and a room-coverage percentage. The sublessor walks to a new area and repeats.
4. **Finish.** When satisfied, they tap Done or Generate. The rest of the existing pipeline (upload, private processing, owner review, explicit publish) stays as it is.

### Room-coverage percentage

As the sublessor captures, the app builds a floor outline from the on-device map. The percentage is the share of that floor that a captured spot can see within about 1.5 m (5 ft). The sublessor never draws anything, and the number only rises as spots are added in new areas. The outline can only include floor the camera has passed over, so a never-seen closet does not count against the sublessor. It is guidance, not a guarantee, and the UI should not present it as a measurement.

### Viewer (inside the iOS app)

- **At a spot:** a full 360° photo sphere. Drag to look around. Circles on the floor mark the other spots, drawn smaller with distance. Tapping one moves you there.
- **Overview:** a top-down or dollhouse view of the rough model with every spot numbered. Tap a spot to enter its 360.
- **Between spots:** a short fade or fly-through the rough model, so you keep your sense of direction. You never stand anywhere except at a captured spot.

## Constraints

- **No LiDAR.** Depth comes from the bundled Depth Anything V2 Small model on the device, used for the live map and coverage, and from Depth Anything 3 on the server, used for the mesh (`processing/room_mesh.py` on `feat/room-mesh`).
- **Little 3D from a spot itself.** Turning in place gives almost no depth information. The 3D model's depth must come from the distance between spots and from frames captured while walking between them. Expect the model to be rougher than today's, which is acceptable because it only plays a supporting role.
- **Handheld parallax.** People turn around their body, not the lens, so nearby objects shift between slices. Stitching must keep seams away from the frame centre and blend them. Small artefacts on close furniture are acceptable, as they are in Matterport's phone capture.
- **One coordinate system.** All spots must share one ARKit world-tracking session so they land on one map. The existing rule stands: an interruption never silently resumes on a new origin.
- **Existing pipeline and policies:** private storage per owner and listing, device file protection, owner review of source images for personal details before upload, serial processing worker with claims and leases, explicit publish, and visibility rechecks on every model request (`docs/mobile/photographic-tours.md`).
- **Current limits will not fit.** Today a take stops at 180 views and the upload limit is 64 MiB. Several spots of high-resolution slices exceed both. The limits must be raised or the format changed (see Builder's calls).

## Calls I made (not discussed with the owner; flag if wrong)

1. **Branch base.** Work starts from `feat/capture-quality`, which already contains `feat/capture-coverage`. `feat/room-mesh` gets merged in, because the viewer's scaffolding needs its server-side mesh. Neither branch has reached `main` yet.
2. **Frames between spots.** While the sublessor walks between spots, the app keeps saving frames using the existing sharp, trackable, parallax policy (`PhotoCapturePolicy.swift`). These feed the 3D model only, never the panoramas. This is the main way to keep the model usable.
3. **The 3D model is the room mesh.** The overview, floor-circle placement and transitions use the `room_mesh.py` coloured mesh. Gaussian splat training is not needed for these tours. The builder may keep it behind a flag but should not show it in the new viewer.
4. **Stitching happens on the server**, in the existing tour worker, using ARKit's camera rotations as the starting alignment, refined by feature matching. It also corrects exposure. The phone shows a quick, unrefined preview of each spot for review only.
5. **Exposure and white balance are locked per spot** while turning, through ARKit's configurable primary capture device, so slices match. Each spot locks again when it starts.
6. **Ceiling and floor.** A single level ring with the main camera covers only the middle band. The dot layout will include tilted passes (likely a level ring plus an upward and a downward ring) to cover the sphere. The exact layout is set by testing on the iPhone 17 before the UI is finalised. The area directly under the sublessor's feet is filled with a neutral disc, as Matterport does.
7. **Tracking loss between spots.** If tracking degrades while walking, show the existing hint. If it is lost, the next spot waits until ARKit relocalizes within the same session. If the session is interrupted (app backgrounded, camera taken), the capture ends with every completed spot kept and can still be generated. An unfinished spot is discarded.
8. **Recovery.** Each completed spot is saved to disk with its slices, poses and lock settings before the map appears, using the same write-before-record pattern as `frames.jsonl`. Reopening recovers completed spots.
9. **Review before upload.** The review screen lets the sublessor preview each spot's 360 and redo or delete a spot while the session is still live.
10. **Viewer technology.** The viewer runs in the app's existing same-origin web view, like today's PlayCanvas viewer (`src/SplatViewer.tsx`, `ios/CuseSublets/RoomToursView.swift`), so the public listing page can show the same tour. The web listing page is not a requirement, though: if a native SwiftUI viewer is clearly better, the builder may choose it and say why.
11. **Spot placement.** A spot is placed at the floor point under the phone's average position during its turn. Floor height comes from ARKit's horizontal plane detection, falling back to the mesh.
12. **Existing tours.** Tours already captured the old way keep their current viewer. This design adds a new tour kind and does not migrate old tours.
13. **Spot capture replaces walk-around capture.** New tours in the marketplace flow use spot capture. The old walk-around flow stays only on the development **Device capture check** screen, for comparison. That screen also gets a spot-capture mode, so the Cuse Capture Test build can exercise it without an account.
14. **One tour, several rooms.** One session can span connected rooms on one level. The coverage percentage covers the whole captured floor, not each room separately.
15. **Overlay vs. map.** The live coverage overlay (blue tint, amber squares) is hidden while turning at a spot, so it doesn't compete with the dots. The top-down map takes over its role as the coverage guidance. The camera keeps running behind the map while the sublessor walks, so walking frames are still saved.
16. **Privacy review covers panoramas.** A stitched 360 shows everything in the room at once. The owner review before publish shows each spot's panorama, not only the source images, and the capture guidance reminds people to put away personal papers before starting.

## Left to the builder

- The exact dot count, the ring tilts, and the alignment tolerance and hold time per dot, tuned on the device.
- Panorama format and resolution (equirectangular vs cubemap), tiling, and compression.
- Whether panorama slices use `captureHighResolutionFrame` or ordinary video frames, after checking sharpness and timing on the iPhone 17.
- How the top-down capture map is rendered on the device (point splats from the coverage voxels or a quick mesh) and how the floor outline is extracted.
- New limits for slice count and upload size, or a per-spot upload format that keeps them bounded.
- Transition animation details, and the overview camera (straight top-down vs angled dollhouse).
- API and storage changes for the new tour kind, the migrations, and how the processor job runs stitching and the mesh.
- Tests: unit tests for the spot and slice state machine, coverage percentage, recovery, and stitching math. Device validation on the iPhone 17 is a release gate, as it is for the current capture.

## Known risks

- Monocular depth makes the live map and coverage approximate. Mirrors, glass and blank walls will mislead it.
- Without LiDAR, DA3 mesh quality with fewer walking frames is unproven. If floor circles misplace badly, spot placement may need to lean on ARKit poses alone.
- Handheld parallax in small rooms, where furniture is close, may make seams more visible than in the Matterport reference.
