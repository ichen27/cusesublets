# Spot capture device results

Results of running the [spot capture test](iphone-17-test-guide.md#spot-capture-test--no-backend-required) on real hardware. Each run records the build commit, device, iOS version, room and lighting.

## Status: the 0.5× layout works on a device; its position fix is untested on a device

The first run used the 1× camera and 29 dots. It stitched without holes, but close objects were doubled where slices overlapped, and 29 dots is far more than comparable apps ask for. Capture now uses the 0.5× camera and 8 dots (six level, ceiling, floor).

The second run (2026-11-13) was the first with the 0.5× camera. All three spots stitched with almost no holes and without the doubling. It also showed four faults, fixed in the build after it:

- **The person was in every panorama.** The floor shot shows their legs on the side the phone's bottom edge points to. The stitcher now uses the floor shot only where the level shots do not reach, and only on the far side. The floor behind the person, which no shot sees, is filled with blurred floor colour. Checked by re-stitching this run's capture.
- **Spots after the first were placed wrongly.** ARKit was paused for each turn and resumed as if the phone had not moved. Tracking now restarts after a turn and is lined up with the tour's world from the motion sensors' heading. Each spot records the correction as `resume_yaw` (degrees) and `resume_shift` (metres). **Not yet run on a device.**
- **Spots after the first were 640 × 480.** ARKit runs the 0.5× lens at that size between turns. The camera's format is now set before every turn.
- **The screen between spots was black.** It now shows the live camera and a rough top-down sketch of the room around each finished spot. The sketch re-draws the spot's slices as six upright views looking down into the room, runs the bundled depth model on each, and scales the result by the floor, whose distance is known from the camera's height. Checked on this run's capture in the simulator: the hallway, bedroom and bathroom each come out with their own outline. It is a sketch, not a measurement.

- **The camera did not look like 0.5×.** The photos were (103° wide, against about 67° for 1×), but the preview filled the tall screen and cropped its sides to roughly 60°. The preview now shows the whole frame with bars above and below. The 0.5× camera also opens before each spot, with Start Capture on it, so the 1× tracking camera is never on screen; between spots the screen is the room sketch with a Next Spot button. **Not yet run on a device.**

After that run the layout changed again, on the owner's request, to match comparable apps: **one level turn of six shots, no ceiling or floor shot**. The panorama then reaches about 50° above and below level, and the stitcher fills the rest with blurred colour. Re-stitching this run's level shots alone gave 0.1–0.2% holes in the band, and dropping one of the six fails as it should (about 9%). With no floor shot the person holding the phone is never photographed. While turning, the screen is now black space with each shot staying where it was taken. **Not yet run on a device.**

The fourth run (2026-11-15), the first with six level dots, stitched cleanly but looked far worse than a comparable app's tour. Three causes, fixed after it:

- **The viewer drew at a third of the screen's sharpness.** The engine renders one pixel per CSS pixel unless told otherwise; on a 3× phone that is a third of the detail each way. It now uses the screen's full resolution.
- **The view was small and narrow.** A 75° view in a box showed a slice of the band and made the fill easy to reach. On a tall screen the tour now fills the screen with a view as tall as the photographed band (about 96°), which shows floor to ceiling at once, and tilt stops 8° into the fill. A level turn with this lens cannot photograph beyond about 50° up or down, so the fill itself cannot shrink without more shots.
- **Detail was thrown away twice.** Slices were 1920 wide (19 pixels a degree) and panoramas 4096 (11). Slices are now 2880, scaled down from the camera's 4032-wide format, and panoramas 8192 (23). **The new capture size has not run on a device.**

The lens measured 103° × 87° after correction (focal 763 px at 1920 × 1440), slightly narrower than the 108° × 92° assumed below, with holes still under 0.1%. The 4° alignment tolerance and 0.5 s hold are unchanged starting values. Tune them from the next device run, and update `SpotLayout.standard` and `SpotTurnTests` together.

## Synthetic baseline (2026-11-12, Mac mini)

These numbers come from a procedurally textured sphere, not a room. They check the geometry and transport only.

| Check | Result |
| --- | --- |
| Sphere coverage above −80°, 8-dot layout, 0.5× lens at 108° × 92° | 100%; holes begin if the lens is narrower than about 104° × 87° (0.2% at that width, 1.2% at 99° × 83°) |
| Stitch vs ground truth, true poses, 2048 wide | ≥ 30 dB PSNR, no holes (unit test) |
| Rotation refinement, 1.5° pose noise, 8 slices | relative error 1.4° → 0.01–0.05° |
| Stitch time, 4096 × 2048 | 8 slices: a few seconds. 29 slices: 62 s with the shared-view matching (11 s before it) |
| Two-spot archive → isolated API → worker → panoramas | ready; 4096 × 2048 JPEGs, ~0.52 MB each; archive 4.2 MB |

## Device runs

| Date | Build | Device / iOS | Room, light | Time per spot | Hard dots | Tracking losses | Coverage % (vs. judgement) | Archive size | Holes per spot | Seams | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-12 | `4b75178` (1×, 29 dots) | iPhone 17 | Bedroom with bathroom door, ceiling light, evening | not timed | not recorded | none reported | not recorded | 6.4 MB, 1 spot, 5 walk frames | 0.0% | Doubled door and door frame; ghosted desk, cart and tripod | Owner feedback: too many dots; wants the 0.5× camera, a real property flow and an in-app viewer |
| 2026-11-13 | `9c43974` (0.5×, 8 dots) | iPhone 17 | Hallway, bedroom and bathroom, ceiling lights, morning | about 22 s (first spot), 18 s (later spots) | not recorded | none reported | not recorded | 3 spots, 2 walk frames | 0.02%, 0.00%, 0.06% | No doubling. Soft seams on the floor near the feet | Owner feedback: their body is in the scan, later dots are in the wrong place, the screen between spots is black, and the start button should be a rectangle labelled Start Capture. Spots 2 and 3 were 640 × 480 |
| 2026-11-15 | `66e07e0` (0.5×, 6 level dots) | iPhone 17 | Hallway, bedroom and bathroom, daylight and ceiling lights | about 14 s | not recorded | none reported | not recorded | 9.3 MB, 3 spots, 6 walk frames | 0.14%, 0.14%, 0.19% of the band | Ghosting on things within about half a metre | Photographed band 48° below to 48° above level. Realignment after each turn applied 62° and 99°. Owner feedback: not clear, blurry, narrow view, and the ceiling and floor fill covers too much |
