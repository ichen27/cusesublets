# Spot capture device results

Results of running the [spot capture test](iphone-17-test-guide.md#spot-capture-test--no-backend-required) on real hardware. Each run records the build commit, device, iOS version, room and lighting.

## Status: first device run done on the old layout; the 0.5× layout is untested on a device

The first run used the 1× camera and 29 dots. It stitched without holes, but close objects were doubled where slices overlapped, and 29 dots is far more than comparable apps ask for. Capture now uses the 0.5× camera and 8 dots (six level, ceiling, floor). The 4° alignment tolerance and 0.5 s hold are unchanged starting values. Tune them from the next device run, and update `SpotLayout.standard` and `SpotTurnTests` together.

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
