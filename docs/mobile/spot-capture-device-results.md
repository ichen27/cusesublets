# Spot capture device results

Results of running the [spot capture test](iphone-17-test-guide.md#spot-capture-test--no-backend-required) on real hardware. Each run records the build commit, device, iOS version, room and lighting.

## Status: the 0.5× layout works on a device; its position fix is untested on a device

The first run used the 1× camera and 29 dots. It stitched without holes, but close objects were doubled where slices overlapped, and 29 dots is far more than comparable apps ask for. Capture now uses the 0.5× camera and 8 dots (six level, ceiling, floor).

The second run (2026-11-13) was the first with the 0.5× camera. All three spots stitched with almost no holes and without the doubling. It also showed four faults, fixed in the build after it:

- **The person was in every panorama.** The floor shot shows their legs on the side the phone's bottom edge points to. The stitcher now uses the floor shot only where the level shots do not reach, and only on the far side. The floor behind the person, which no shot sees, is filled with blurred floor colour. Checked by re-stitching this run's capture.
- **Spots after the first were placed wrongly.** ARKit was paused for each turn and resumed as if the phone had not moved. Tracking now restarts after a turn and is lined up with the tour's world from the motion sensors' heading. Each spot records the correction as `resume_yaw` (degrees) and `resume_shift` (metres). **Not yet run on a device.**
- **Spots after the first were 640 × 480.** ARKit runs the 0.5× lens at that size between turns. The camera's format is now set before every turn.
- **The screen between spots was black.** It now shows the live camera and a top-down picture of the floor each spot captured.

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
