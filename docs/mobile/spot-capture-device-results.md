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
- **The view was small and narrow.** A 75° view in a box showed a slice of the band and made the fill easy to reach. On a tall screen the tour now fills the screen with a view as tall as the photographed band (about 96°), which shows floor to ceiling at once, floor to ceiling at once. A level turn with this lens cannot photograph beyond about 50° up or down, so the fill itself cannot shrink without more shots.
- **The fill and the finish.** Above and below the band, each direction now keeps the colour at the edge of what was photographed and blurs sideways towards the pole, instead of a flat blur, and the viewer looks freely up and down again. After stitching, dim areas are lifted (a spot has one exposure, locked on the first dot, so Test 4's hallway was murky) and fine detail is sharpened.
- **Detail was thrown away twice.** Slices were 1920 wide (19 pixels a degree) and panoramas 4096 (11). Slices are now 2880, scaled down from the camera's 4032-wide format, and panoramas 8192 (23). **The new capture size has not run on a device.**

**What the iPhone 17 reports about its cameras** (read from the device on 2026-11-15):

- ARKit world tracking offers only the 1× camera (`builtInWideAngleCamera`), in every format. The hand-off to the 0.5× camera for a turn is therefore necessary.
- The 0.5× camera's 4:3 formats are 1920 × 1440, 2592 × 1944, 3264 × 2448 and 4032 × 3024. All report a field of view of 103.6° uncorrected and 106.2° with geometric distortion correction. So switching the correction off would not widen the view, and one level turn cannot photograph much beyond 50° above or below level.
- **Open question:** capture enables the correction, yet the intrinsics delivered with each frame give 103.0°, the uncorrected figure. If the frames really span 106.2°, the stitcher places them with a focal length about 5% too long, which would put edges up to 2.5° apart at seams. The arm swing below is several times larger and hides it. Settling it needs a capture turned about the lens (a tripod) or the calibration data that photo capture provides.

**Why seams doubled** (measured on the fourth run's capture, 2026-11-15):

- **The phone swings on the arm.** A person turning on the spot holds the phone 0.2–0.35 m in front of them, so each shot is taken from a different place. On the six seams with the most matched features (11 to 69 each), the same feature sat a median 5° to 10° apart in the two shots, always in the direction that swing gives. The angle is the swing divided by the distance: 0.3 m and a wall 2 m away is about 9°. In these small rooms that is everything in view, not only nearby things.
- **The stitcher mixed the two shots across the whole overlap**, which draws everything there twice. It now takes each pixel from one shot. The shots meet along a line chosen where they agree, so something they place differently is drawn once, whole. Only broad light and shade is mixed across the line (2° of arc), so plain walls do not show a step. Re-stitching this run: the doubled door frame, shelf, monitor arm and hair dryer are each drawn once.
- **What that does not fix.** Each shot still shows the room from its own place. Where two meet, a strip of the room between them can be missing, something standing there can be cut short, and long straight edges such as the line of the ceiling can kink. Only a smaller swing fixes that.
- **Rotation refinement made it worse.** It tried to explain the swing by turning the shots: every shot went to its 3° limit, some tilted sideways by 3.5°, and the seams agreed no better (mismatch 0.84 before and after on spot 1). It now gives up and keeps the sensed rotations when any shot would need more than its limit.
- **Tried and not adopted:** shifting each shot as if the room were a shell at a fitted distance (one per seam, or per seam and height). The simple shells explained little (mismatch 0.84 to 0.78) because furniture, doors and walls at one seam are at very different distances, and the flexible one bent straight edges into steps and opened gaps.
- **Not done yet, at capture:** turning the phone about itself and stepping round it, as on a tripod, would cut the swing to a few centimetres. More shots per turn would also halve the gap between neighbours. Neither has been tried on a device.

**Sharpening slices with a model** (tried on the fourth run's capture, 2026-11-15, Apple M4):

- Real-ESRGAN's 2× model on each slice before stitching gave visibly cleaner edges and texture in the panorama (a hair dryer's mesh, cords, embossed paper) at 10.7 s a slice. SwinIR's 2× model looked about the same on a crop and took roughly ten times as long; Real-ESRGAN's small general model looked painterly.
- With the model, the stitcher's own sharpening made the result harsh, so it is left out for enhanced slices.
- Small lettering came out sharper but cannot be trusted to be right.
- The whole three-spot job took 4 min 2 s with the model against about 1.5 min without.
- **Not measured:** the 2880-wide slices the current app saves. No scan at that size exists yet.

**Dots lowered by 15°** (2026-11-15, on the owner's request: the floor matters more than the ceiling):

- One turn photographs a band about 96° tall, so every degree the shots tip down moves that band from ceiling to floor. Stitching synthetic rings with the measured lens gave, for a phone 1.4 m up in a 2.4 m room:

  | Tilt | Band | Floor seen from | Ceiling line kept for walls beyond |
  | --- | --- | --- | --- |
  | 0° (before) | −48° to +48° | 1.26 m | 0.90 m |
  | 10° | −59° to +38° | 0.85 m | 1.27 m |
  | **15° (now)** | −64° to +33° | 0.69 m | 1.52 m |
  | 20° | −69° to +29° | 0.53 m | 1.84 m |
  | 25° | −75° to +24° | 0.38 m | 2.27 m |

  Holes stayed under 0.1% of the band at every tilt.
- **What it costs.** Cropping the fourth run's shots to the top edge a 15° tilt gives, and re-stitching, shows the loss: in the hallway, where the door is under a metre away, the top of the door frame and the ceiling above it become streaks of fill. Rooms with walls further than 1.5 m keep the ceiling line.
- The viewer now opens looking at the middle of what a spot photographed (15° down for these spots), so the fill above is off screen until the viewer looks up.
- **Not yet run on a device.** The floor near the feet is the closest thing in the picture, so the arm's swing shifts it most between shots; patterned floors (boards, tiles) may kink where shots meet. The gain at the floor cannot be previewed from an earlier scan.

**Capture flow reworked** (2026-11-15, on the owner's feedback after comparing with a similar app):

- One tap on the map now opens the camera with the turn already begun. Before, the camera opened for framing and a second button started the turn. The dot is drawn at once and no longer waits for the camera's first picture.
- The map can be zoomed and moved, spots are not numbered, and a tapped spot can be previewed, captured again, deleted or dragged, on the capture map itself.
- **The black camera screen, measured on the iPhone 17 (2026-11-15).** Alone, the 0.5× camera delivered its first picture 0.27 s after being started. Started straight after ARKit was paused, it took 9.2 s, twice out of two, and all 9.0 s were spent setting the camera's picture size before starting the session. ARKit uses this lens for its own tracking and evidently holds on to it after a pause. That step was added after the second run, to undo the 640 × 480 size ARKit leaves the lens at, so every spot since has probably opened on about nine seconds of black (inferred from the same code path; earlier builds were not timed). The session is now started first and the size set afterwards, with no pictures delivered until the size is right. Timed the same way after the change, three times out of three: the first full-size picture came 0.80 to 0.85 s after ARKit was paused (about 0.3 s to start, 0.3 s to change the size from ARKit's 640 × 480, 0.2 s for distortion correction and focus), and 0.47 s with no ARKit before. The phone lay on a desk for these runs, so ARKit's tracking was limited; the hand-off inside a real scan has not been timed, and the app logs each step so that it can be.
- Each spot also records `camera_delay` (seconds from the tap to the camera's first picture) and `sketch_delay` (seconds from its last shot to its sketch) in the take, so the next scan gives real numbers.
- **No scanning between spots.** The owner read the walked-floor picture and its hints ("Hold steadier") as a second way of capturing. Walk frames, the floor picture and the hints are gone; ARKit only follows the phone. The room mesh loses its walk frames (see the worker's step 6).
- **Not yet run on a device.** None of this can run in the simulator, which has no ARKit world tracking. Check on the phone: zoom and drag on the map, tapping and dragging spots, and that the first shot's exposure is right now that it can be taken soon after the camera opens.

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
