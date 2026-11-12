# Spot capture device results

Results of running the [spot capture test](iphone-17-test-guide.md#spot-capture-test--no-backend-required) on real hardware. Each run records the build commit, device, iOS version, room and lighting.

## Status: device run pending

No real-iPhone spot capture has been run yet. The dot layout (12 level, 8 at +50°, 8 at −50°, 1 straight up), the 4° alignment tolerance and the 0.5 s hold are starting values. Tune them from the first device run, and update `SpotLayout.standard` and `SpotTurnTests` together.

## Synthetic baseline (2026-11-12, Mac mini)

These numbers come from a procedurally textured sphere, not a room. They check the geometry and transport only.

| Check | Result |
| --- | --- |
| Sphere coverage above −80° with the 29-dot layout, ring tilt 50° | 100% (a 45° tilt leaves 1.3% uncovered) |
| Stitch vs ground truth, true poses, 2048 wide | ≥ 30 dB PSNR, no holes (unit test) |
| Rotation refinement, 1.5° pose noise | mean error 1.48° → 0.05° |
| Stitch time, 4096 × 2048, 29 slices | 12.3 s |
| Two-spot archive → isolated API → worker → panoramas | ready; 4096 × 2048 JPEGs, ~0.52 MB each; archive 4.2 MB |

## Device runs

| Date | Build | Device / iOS | Room, light | Time per spot | Hard dots | Tracking losses | Coverage % (vs. judgement) | Archive size | Holes per spot | Seams | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | | |
