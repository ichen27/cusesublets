# Spot-Capture 360° Tours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace walk-around Gaussian capture with Matterport-style spot capture: a guided turn in place at each spot, a top-down capture map with a coverage percentage, server-stitched 360° panoramas, and a Street View-style in-app viewer that jumps between spots over a rough room mesh.

**Architecture:** The iPhone records one ARKit session per tour. Turning at a spot saves *slice* frames on guided dot targets with exposure locked. Walking between spots saves *walk* frames using the existing parallax policy. Both go into the existing take folder (`frames.jsonl` plus a new `spots.jsonl`) and package as a version 2 `.roomcapture`. A new tour kind, `spots`, flows through the existing upload, claim and lease API. The worker stitches one equirectangular JPEG per spot, builds the Depth Anything 3 room mesh, and uploads a USTAR bundle whose byte offsets let the viewer fetch each panorama on its own. The viewer is a PlayCanvas page inside the existing same-origin `/tour-viewer` web view.

**Tech Stack:** Swift/SwiftUI/ARKit/SceneKit (iOS 18 target, XcodeGen `ios/project.yml`), Cloudflare Workers + D1 + R2 (TypeScript, vitest), Python 3 worker (NumPy, OpenCV headless, SciPy; Depth Anything 3 + Open3D for the mesh), PlayCanvas 2.23 + React 19 (Vite).

**Spec:** `docs/superpowers/specs/2026-11-12-spot-capture-tours-design.md`. Read it first. This plan argues from it and from `docs/mobile/photographic-tours.md`.

## Global Constraints

- No LiDAR assumed. The test device is a regular iPhone 17. Every path must work with `ARWorldTrackingConfiguration` and the main wide camera.
- One ARKit world-tracking session per tour. An interruption never silently resumes on a new origin.
- Keep every existing privacy rule: owner/listing-specific folder, `FileProtectionType.complete`, excluded from backup, image written before its record, private R2 objects, explicit publish, and visibility rechecked on every model, mesh and panorama request.
- Spot captures are limited to **8 spots** and **90 walk frames**. Archives must stay at or under **96 MiB**, below the Workers request-body limit. Splat captures keep the existing 64 MiB and 180-view limits unchanged.
- Slice images are saved **1440 px wide**. Walk frames keep **1920 px**, as today.
- Panoramas are equirectangular, **4096 × 2048**, JPEG quality **85**. Yaw 0 is ARKit world −Z, +Y is up, and pixel column increases with clockwise yaw seen from above.
- Floor circles are visible up to **6 m** from the current spot. A tap selects a circle within **0.35 m** of the tapped floor point.
- Coverage percentage = share of the seen floor visible from a completed spot within **1.5 m**, with walls blocking the line of sight.
- Hints appear only for lasting problems: reuse `CaptureHintFilter` and its 0.6 s / 1.5 s delays.
- Existing splat tours keep their current viewer and API behaviour. Old rows default to `kind = 'splat'`.
- After adding Swift files, run `xcodegen generate` in `ios/` and commit the regenerated `CuseSublets.xcodeproj`.
- Commit as `ichen27 <ivan27chen@gmail.com>`. No AI attribution anywhere.

## Review Focus

1. **Tracking lost or app backgrounded mid-turn.** The unfinished spot is discarded, completed spots survive, and the next spot can start only after tracking is normal again. Pinned in Task 5 (`SpotSessionTests`).
2. **App killed after some slices of a spot were written.** Recovery reports only completed spots. The stitcher ignores slices whose spot never completed, and those frames still feed the mesh. Pinned in Task 4 (`SpotTakeTests.testRecoveryDropsUnfinishedSpot`) and Task 9 (`test_ignores_slices_of_unfinished_spots`).
3. **Upload budget runs out mid-spot.** A spot may start only if the budget can hold a whole spot of slices, so the take never ends half-turned. Pinned in Task 4 (`SpotTakeTests.testBudgetRefusesSpotThatCannotFit`).
4. **Phone held at an angle or rolled while turning.** Alignment uses the camera's forward direction, not screen axes. The stitcher uses each slice's full rotation, roll included. Pinned in Task 2 (`testRollDoesNotAffectAlignment`) and Task 9 (`test_rolled_slices_stitch`).
5. **Every spot deleted, or the tour generated with no completed spot.** Generate is disabled with zero spots, and packaging throws. Pinned in Task 4 (`testPackagingNeedsOneSpot`).

---

## Phase A: Branch base

### Task 1: Merge `feat/room-mesh` into `feat/spot-tours`

**Files:**
- Modify: merge commit only.

- [ ] **Step 1: Merge.** In `/Volumes/SamsungSSD1/code/cusesublets-spot-tours`, run `git fetch origin && git merge --no-ff origin/feat/room-mesh -m "Merge room mesh into spot tours"`. A trial `git merge-tree` on 2026-11-12 showed no conflicts.
- [ ] **Step 2: Regenerate the Xcode project.** Run `cd ios && xcodegen generate && cd ..`. Expected: no diff, or only file-reference changes. Commit them if present.
- [ ] **Step 3: Run the existing checks.** Run `npm ci && npm run typecheck && npm test && python3 tests/tour-processor-unit.py && npm run build`. Expected: all pass. Run the iOS unit tests with `xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CuseSubletsTests test`. Expected: `** TEST SUCCEEDED **`. (Use any installed iPhone simulator name in this and every later iOS test command.)
- [ ] **Step 4: Push.** Run `git push`.

---

## Phase B: iPhone capture

### Task 2: Dot layout and the turn state machine

**Files:**
- Create: `ios/CuseSublets/SpotTurn.swift`
- Test: `ios/CuseSubletsTests/SpotTurnTests.swift`

**Interfaces:**
- Produces:
  - `struct SpotTarget: Equatable { let ring: Int; let yaw: Float; let pitch: Float }`. Yaw is measured relative to the spot's starting heading, in radians. Pitch is positive upwards.
  - `enum SpotLayout { static let standard: [SpotTarget] }`. Ring 0: 12 targets at pitch 0°, yaw step 30°. Ring 1: 8 targets at pitch +50°, step 45°. Ring 2: 8 targets at pitch −50°, step 45°. Ring 3: 1 zenith target at +90°. That is 29 targets. These are starting values, tuned in Task 13.
  - `struct SpotTurn` with `init(layout: [SpotTarget] = SpotLayout.standard, startYaw: Float)`, `static let alignTolerance: Float = 4° (radians)`, `static let holdDuration = 0.5`, `var current: SpotTarget?`, `var holdProgress: Double` (0…1), `var progress: Double` (captured / total), `var isComplete: Bool`, `var captured: [Int]` (layout indices in capture order), `mutating func update(forward: SIMD3<Float>, time: Double, steady: Bool) -> SpotTurnEvent`, `mutating func undo() -> Int?` (returns the removed layout index), and `func direction(of target: SpotTarget) -> SIMD3<Float>` (world, gravity-aligned).
  - `enum SpotTurnEvent: Equatable { case none, aligning, capture(index: Int), complete }`.
  - `current` is the nearest uncaptured target in the lowest-numbered ring that still has any uncaptured target. "Nearest" is the smallest yaw difference from the current heading.

- [ ] **Step 1: Write the failing tests.**

```swift
final class SpotTurnTests: XCTestCase {
  func testLayoutHas29TargetsInFourRings() {
    XCTAssertEqual(SpotLayout.standard.count, 29)
    XCTAssertEqual(Set(SpotLayout.standard.map(\.ring)), [0, 1, 2, 3])
  }
  func testHoldingOnTargetCapturesAfterHoldDuration() {
    var turn = SpotTurn(startYaw: 0)
    let d = turn.direction(of: turn.current!)
    XCTAssertEqual(turn.update(forward: d, time: 0, steady: true), .aligning)
    XCTAssertEqual(turn.update(forward: d, time: 0.49, steady: true), .aligning)
    XCTAssertEqual(turn.update(forward: d, time: 0.51, steady: true), .capture(index: 0))
    XCTAssertEqual(turn.captured, [0])
  }
  func testUnsteadyFrameResetsHold() {
    var turn = SpotTurn(startYaw: 0)
    let d = turn.direction(of: turn.current!)
    _ = turn.update(forward: d, time: 0, steady: true)
    _ = turn.update(forward: d, time: 0.3, steady: false)
    XCTAssertEqual(turn.holdProgress, 0)
    XCTAssertEqual(turn.update(forward: d, time: 0.6, steady: true), .aligning)
  }
  func testOffTargetBeyondToleranceDoesNotAlign() { /* rotate d by 5° → .none, holdProgress 0 */ }
  func testRollDoesNotAffectAlignment() { /* same forward vector, any roll → still captures */ }
  func testLevelRingFinishesBeforeUpperRing() { /* capture all ring-0 targets → current.ring == 1 */ }
  func testUndoRemovesLastAndMakesItCurrent() { /* capture 2, undo() == second index, current is that target */ }
  func testCompleteAfterAllTargets() { /* capture 29 → last event .complete, isComplete, progress == 1 */ }
}
```

- [ ] **Step 2: Run and see them fail.** Run `xcodebuild … -only-testing:CuseSubletsTests/SpotTurnTests test`. Expected: compile failure, because `SpotTurn` is undefined.
- [ ] **Step 3: Implement `SpotTurn.swift`.** Alignment is `acos(dot(forward, direction(of: current))) < alignTolerance`. The hold starts at the first aligned, steady frame. It captures once `time − holdStart ≥ holdDuration`. Any frame that is unaligned or not steady resets the hold.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git add ios/CuseSublets/SpotTurn.swift ios/CuseSubletsTests/SpotTurnTests.swift ios/CuseSublets.xcodeproj && git commit -m "Add guided dot layout and turn state for spot capture"`

### Task 3: Floor coverage and the top-down map

**Files:**
- Create: `ios/CuseSublets/FloorCoverage.swift`
- Modify: `ios/CuseSublets/CaptureCoverage.swift` (`CoverageMap`: store an average RGB per cell; add `func topDown() -> [TopDownCell]`)
- Modify: `ios/CuseSublets/CaptureCoverageEngine.swift` (pass the model input image's colours into `integrate`; expose `onMap: (([TopDownCell]) -> Void)?`)
- Test: `ios/CuseSubletsTests/FloorCoverageTests.swift`, `ios/CuseSubletsTests/CaptureCoverageTests.swift`

**Interfaces:**
- Produces:
  - `struct TopDownCell: Equatable { let x: Int32; let z: Int32; let floor: Bool; let top: Float; let color: SIMD3<Float> }`, on the 10 cm grid. `floor` means the column's lowest occupied voxel is within 0.15 m of `floorY`. `top` is the highest occupied y. `color` is the topmost voxel's colour.
  - `CoverageMap.integrate(depth:camera:trackedPoints:colors:stride:)` gains `colors: ((Int, Int) -> SIMD3<Float>)?`, defaulting to `nil`, which keeps the current callers and tests valid.
  - `CoverageMap.topDown(floorY: Float) -> [TopDownCell]`.
  - `enum FloorCoverage { static let reach: Float = 1.5; static func fraction(cells: [TopDownCell], spots: [SIMD2<Float>]) -> Double }`. The denominator is the floor cells. The numerator is the floor cells within `reach` of some spot along a 2D line, where no cell on the line has `top > floorY + 0.3` and `floor == false`. Such a cell is an obstacle, like a wall or a tall piece of furniture.
  - `static func estimateFloorY(planes: [Float], cells: [SIMD3<Float>]) -> Float?`: the lowest horizontal ARKit plane if any, otherwise the 5th percentile of voxel-centre y, otherwise nil.

- [ ] **Step 1: Write the failing tests.** `testEmptyRoomWithOneCentralSpotCoversDisc`: a 4 × 4 m floor with one spot at the centre gives a fraction near π·1.5²/16, within ±0.03. `testWallBlocksSightLine`: a wall row of obstacle cells splitting the room means floor behind it doesn't count. `testUnseenFloorDoesNotCount`: removing cells shrinks the denominator, so the fraction rises. `testNoSpotsIsZero`. `testFloorFromLowestPlane` and `testFloorFallsBackToPercentile`. In `CaptureCoverageTests`, add `testIntegrateRecordsCellColour` (constant red input gives red `topDown` cells) and keep the existing tests unchanged.
- [ ] **Step 2: Run and see them fail.** Run `-only-testing:CuseSubletsTests/FloorCoverageTests -only-testing:CuseSubletsTests/CaptureCoverageTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Use 2D DDA/Bresenham over the 10 cm grid for line of sight. Colours come from the 518 × 392 model input the engine already builds, sampled at the same pixel as the depth.
- [ ] **Step 4: Run the tests.** Expected: PASS, including all the earlier `CaptureCoverageTests`.
- [ ] **Step 5: Commit.** `git commit -m "Measure floor coverage from capture spots and keep colour for the top-down map"`

### Task 4: The spot take on disk: records, budget, recovery and packaging

**Files:**
- Create: `ios/CuseSublets/SpotTake.swift`
- Modify: `ios/CuseSublets/CaptureStorage.swift` (`CaptureFrameRecord` gains `role` and `spot`; `CaptureBudget` takes `archiveLimit`; `CaptureManifest` gains `spots`)
- Modify: `ios/CuseSublets/PhotoCaptureArchive.swift` (`limit` and `limitMessage` passed by the caller for spot takes)
- Test: `ios/CuseSubletsTests/SpotTakeTests.swift`, `ios/CuseSubletsTests/CaptureStorageTests.swift`

**Interfaces:**
- Produces:
  - `CaptureFrameRecord.role: String = "walk"` (`"walk"` | `"slice"`) and `spot: Int? = nil` (spot number, for slices), with JSON keys `role` and `spot`. Records without them decode as walk frames, so old takes still load.
  - `CaptureManifest.schemaVersion` is 2 for spot takes. It gains `capture: String` (`"spots"` | `"splat"`, default `"splat"`, key `capture`) and `spots: [SpotRecord]?`.
  - `struct SpotRecord: Codable, Equatable { var spot: Int; var slices: [String]; var position: [Double]; var floorY: Double; var startYaw: Double; var exposureDuration: Double; var iso: Double }`, with keys `spot`, `slices`, `position`, `floor_y`, `start_yaw`, `exposure_duration`, `iso`. `slices` holds the images' `file_path`s.
  - `enum SpotTake` with:
    - `static func folder(owner: String, listing: String) -> URL`: the same SHA-256 key as `PhotoCaptureDraft.folder`, but under Application Support `spot-captures/`, so a spot take never collides with a leftover walk-around take for the same listing.
    - `static let maximumSpots = 8`, `maximumWalkFrames = 90`, `archiveLimit = 96 * 1024 * 1024`, `sliceWidth: CGFloat = 1440`, `spotsName = "spots.jsonl"`
    - `static var maximumViews: Int { maximumSpots * SpotLayout.standard.count + maximumWalkFrames }`
    - `static func appendSpot(_ spot: SpotRecord, to folder: URL) throws`, written atomically per line with complete file protection. A tombstone line `{"spot":N,"deleted":true}` marks a deleted spot.
    - `static func deleteSpot(_ spot: Int, in folder: URL) throws`
    - `static func savedSpots(in folder: URL, frames: [CaptureFrameRecord]) -> [SpotRecord]`: completed, non-deleted spots whose every slice is among the complete `frames`.
    - `static func package(folder: URL) throws -> URL`: writes manifest version 2 with `capture: "spots"` and archives `manifest.json` plus every complete frame. It throws `"Capture at least one spot before generating."` when there are no saved spots.
  - `CaptureBudget.init(maximumViews:archiveLimit:)` and `func canFit(views: Int, averageImage: Int) -> Bool`. The spot recorder calls `canFit(views: SpotLayout.standard.count, averageImage: budget.target)` before starting a spot.
  - `CaptureWriter.init(folder:budget:)` takes the budget, and `save` takes a `width` per frame, so slices are 1440 and walk frames 1920.

- [ ] **Step 1: Write the failing tests.**
  - `testRecordWithoutRoleDecodesAsWalk`
  - `testSpotRecordRoundTripsWithSnakeCaseKeys`
  - `testRecoveryDropsUnfinishedSpot`: frames for spots 1 and 2 are written, but only spot 1 is in `spots.jsonl`. `savedSpots` returns `[1]`, and the package still contains spot 2's frames.
  - `testDeletedSpotIsNotSaved`
  - `testPackagingNeedsOneSpot`: it throws the exact message above.
  - `testBudgetRefusesSpotThatCannotFit`: a budget filled to 95 MiB returns `canFit(views: 29, …) == false`.
  - `testSplatBudgetUnchanged`: the default `CaptureBudget()` still uses 64 MiB and 180 views.
  - `testManifestV2HasCaptureAndSpots`: decode the packaged `manifest.json` and assert `schema_version == 2`, `capture == "spots"` and `spots.count == 1`.
- [ ] **Step 2: Run and see them fail.** Run `-only-testing:CuseSubletsTests/SpotTakeTests -only-testing:CuseSubletsTests/CaptureStorageTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Reuse `PhotoRecorder.savedFrames(in:)` for frames. Call `CaptureArchive.write(entries:to:limit:limitMessage:)` with `SpotTake.archiveLimit` and the message `"Capture exceeds 96 MB. Remove a spot and try again."`
- [ ] **Step 4: Run the tests.** Expected: PASS, including the existing `CaptureStorageTests`.
- [ ] **Step 5: Commit.** `git commit -m "Store spot captures with per-spot records, recovery and a 96 MB budget"`

### Task 5: The spot recorder: session, modes, exposure lock and tracking loss

**Files:**
- Create: `ios/CuseSublets/SpotSession.swift` (pure state, unit-tested)
- Create: `ios/CuseSublets/SpotRecorder.swift` (ARKit delegate, device-tested)
- Test: `ios/CuseSubletsTests/SpotSessionTests.swift`

**Interfaces:**
- Consumes: `SpotTurn` (Task 2), `FloorCoverage` and `TopDownCell` (Task 3), `SpotTake`, `SpotRecord` and `CaptureBudget` (Task 4), and the existing `CapturePolicy`, `CaptureHintFilter`, `CaptureWriter` and `CaptureCoverageEngine`.
- Produces:
  - `enum SpotPhase: Equatable { case map, turning(spot: Int), relocating, ended(reason: String) }`
  - `struct SpotSession` with `var phase: SpotPhase`, `var completed: [Int]`, `mutating func startSpot(budgetFits: Bool, tracking: Bool) -> Bool`, `mutating func trackingChanged(normal: Bool)`, `mutating func spotFinished()`, `mutating func interrupted()`, and `var canGenerate: Bool`.
    - Tracking that is limited while turning abandons the spot: `phase = .relocating`, nothing is appended.
    - `.relocating` returns to `.map` when tracking is normal.
    - `interrupted()` sets `.ended(reason: "Capture ended. Your finished spots are saved.")`.
    - `startSpot` refuses at `SpotTake.maximumSpots`, when the budget doesn't fit, or when tracking isn't normal.
  - `final class SpotRecorder: NSObject, ObservableObject, ARSessionDelegate`, `init(draft: PhotoCaptureDraft)`, storing the take in `SpotTake.folder(owner:listing:)`. Its configuration is the existing `PhotoRecorder` one plus `planeDetection = [.horizontal]`. Horizontal plane anchors' world y values feed `FloorCoverage.estimateFloorY`. It publishes:
    - `phase`, `turn: SpotTurn?`, `spots: [SpotRecord]`, `mapCells: [TopDownCell]`, `coverage: Double`, `hint: CaptureHint?`, `you: SIMD2<Float>?`
    - methods `start()`, `beginSpot()`, `undoSlice()`, `finish()`, `deleteSpot(_:)`, `redoSpot(_:)` (deletes and immediately begins a spot)
- Behaviour to implement (all from the spec):
  - **Map phase.** Walk frames go through the existing `CapturePolicy.evaluate`, up to `SpotTake.maximumWalkFrames`, at 1920 px with `role: "walk"`. The coverage engine keeps running, and `mapCells` and `coverage` refresh.
  - **Turning phase.** Lock exposure and white balance via `ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera` (`lockForConfiguration`, `.locked` exposure and white balance). Unlock to continuous at spot end or abandonment. "Steady" means the policy's motion is under the existing smear limit (`CapturePolicy` motion threshold, 4 px) and tracking is normal. On `.capture(index)` save the frame at 1440 px with `role: "slice"` and `spot: n`. While `writer.busy` is true, pass `steady: false`, so the hold waits and never drops a slice. On `.complete`, append the `SpotRecord`: `position` is the mean slice camera position, `floorY` comes from `FloorCoverage.estimateFloorY`, and the exposure values are the lock values. Then return to `.map`.
  - **Undo.** Mark the last slice superseded by recording its layout index as uncaptured. The frame stays on disk and serves only the mesh. Only slices listed in `SpotRecord.slices` reach the stitcher.
  - **Session interruption or backgrounding.** Call `SpotSession.interrupted()`, pause the session, and keep the folder.

- [ ] **Step 1: Write the failing tests.**
  - `testTrackingLossWhileTurningAbandonsSpotAndRelocates`
  - `testRelocatingReturnsToMapWhenNormal`
  - `testCannotStartNinthSpot`
  - `testCannotStartWhenBudgetFull`
  - `testInterruptionKeepsCompletedSpots`
  - `testCanGenerateNeedsOneSpot`
- [ ] **Step 2: Run and see them fail.** Run `-only-testing:CuseSubletsTests/SpotSessionTests`. Expected: compile failure.
- [ ] **Step 3: Implement `SpotSession.swift`, then `SpotRecorder.swift`.** Model `SpotRecorder` on `PhotoRecorder` for permission, folder setup, video format choice and the backgrounding observer. Do not modify `PhotoRecorder`.
- [ ] **Step 4: Run the tests.** Expected: PASS. Then run the full `CuseSubletsTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Record spot captures in one ARKit session with locked exposure and tracking recovery"`

### Task 6: Capture screens: turn, map and review with the on-device 360 preview

**Files:**
- Create: `ios/CuseSublets/SpotCaptureScreens.swift` (`SpotCaptureScreen` hosting `SpotTurnView`, `SpotMapView`, `SpotReviewView`)
- Create: `ios/CuseSublets/SpotPreview.swift` (SceneKit preview)
- Modify: `ios/CuseSublets/DeviceCaptureCheckView.swift` (a "Spot capture" section next to the existing camera test, using its own local folder, listing `local-device-check-spots`)
- Modify: `ios/CuseSublets/RoomToursView.swift` (new tours open `SpotCaptureScreen`, and local recovery looks in `SpotTake.folder`; the upload change waits for the API and lands in Task 12)
- Test: `ios/CuseSubletsUITests/PersonalDeviceTests.swift` (the simulator reports capture as unavailable: assert the Spot capture section and its disabled button render)

**Interfaces:**
- Consumes: `SpotRecorder` (Task 5), and `SpotTake.package` and `savedSpots` (Task 4).
- Produces: `struct SpotCaptureScreen: View { init(recorder: SpotRecorder) }` and `struct SpotPreview: UIViewRepresentable { init(folder: URL, spot: SpotRecord, frames: [CaptureFrameRecord]) }`.
- Copy (exact):
  - Turn caption: `"Point the camera at the dot"`
  - After 1.5 s with the target off screen: `"Turn to the dot"`
  - Undo button: `"Undo"`
  - Map header: `"\(Int(coverage*100))% of room captured"` and `"\(spots.count) spots"`
  - Map shutter accessibility label: `"Capture a spot here"`
  - Map Done button: `"Done"`
  - Review buttons: `"Preview 360"`, `"Redo spot"`, `"Delete spot"`, `"Generate tour"`
  - Before the first spot: `"Put away personal papers and photos. Each spot captures the whole room around you."`
  - The coverage caption must also say `"Covers floor you've walked past; unseen areas don't count."`, so the percentage is not presented as a measurement.
- Layout, matching the approved mockups:
  - **Turn view.** The camera is full screen, with a fixed 64 pt reticle in the centre and the target dot projected into the view. When the dot is off screen, a dotted line runs from the reticle to the screen edge in its direction. `holdProgress` is drawn as a stroke sweeping around the reticle. An overall `progress` bar sits above Undo. The coverage overlay is hidden in this view.
  - **Map view.** A SwiftUI `Canvas` draws `mapCells` from above. Floor cells use their colour, obstacles are darker, and the view auto-fits the cells' bounds. It shows numbered hexagons at spot positions, a green dot at `you`, the header text, the shutter and Done.
  - **Review view.** The map plus a list of spots. Each spot has Preview 360 (`SpotPreview`), Redo and Delete. Generate is disabled unless `canGenerate`.
- `SpotPreview`: a SceneKit camera at the origin. Each slice is an `SCNPlane` at distance 1, oriented by the slice's rotation, sized from fx/fy and width/height, and textured with the JPEG. Drag to look. It is not stitched and is labelled `"Rough preview — the tour is stitched after upload."`

- [ ] **Step 1: Update the UI test.** Assert `app.buttons["Start spot capture"]` exists and is disabled on the simulator, and that `"Photographic capture"` still reads `"Unavailable"`.
- [ ] **Step 2: Run and see it fail.** Run `xcodebuild … -scheme "Cuse Capture Test" test`. Expected: FAIL, because the button doesn't exist.
- [ ] **Step 3: Implement the screens and wire them into `DeviceCaptureCheckView` and `RoomToursView`.**
- [ ] **Step 4: Run the tests.** Run the Cuse Capture Test scheme and the `CuseSublets` scheme. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit.** `git commit -m "Add guided spot capture, capture map and review screens"`

---

## Phase C: Server

### Task 7: Tour kind, spot result contract, migration and panorama route

**Files:**
- Create: `shared/spot-tour.ts`
- Create: `migrations/0020_spot_tours.sql`
- Modify: `shared/room-tour.ts` (`RoomTour.kind: TourKind`; `RoomTour.result: TourResult | SpotTourResult | null`)
- Modify: `worker/room-tours.ts` (create accepts `kind`; size limit by kind; claim returns `kind`; completion validates by kind; new `panorama/{n}` route)
- Test: `tests/spot-tour.test.ts`, `tests/room-tour.test.ts`, `tests/tours-runtime.py`

**Interfaces:**
- Produces:
  - `export type TourKind = "splat" | "spots"` and `export const SPOT_TOUR_LIMIT = 96 * 1024 * 1024`
  - `export interface SpotPanorama { offset: number; length: number; width: 4096; height: 2048 }`
  - `export interface TourSpot { spot: number; position: [number, number, number]; floorY: number; panorama: SpotPanorama }`
  - `export interface SpotTourResult { method: string; spots: TourSpot[]; slices: number }`
  - `export function validateSpotTourResult(value: unknown, bundleSize: number): SpotTourResult`. It requires 1–8 spots, unique spot numbers, finite coordinates under 10000, `offset % 512 === 0`, `offset + length <= bundleSize`, non-overlapping ranges and `length <= 16 MiB`. It drops unknown fields.
  - The migration is exactly: `ALTER TABLE room_tours ADD COLUMN kind TEXT NOT NULL DEFAULT 'splat' CHECK(kind IN ('splat','spots'));`
  - The create body gains `kind` (default `"splat"`). The size check uses `kind === "spots" ? SPOT_TOUR_LIMIT : TOUR_LIMIT`. The 413 message for spots is `"Choose a capture under 96 MB"`.
  - The claim response job includes `kind`.
  - On `complete`, for `kind = 'spots'`, the uploaded file is the bundle and `X-Tour-Result` is validated with `validateSpotTourResult(…, X-File-Size)`.
  - `GET /api/listings/{listing}/tours/{tour}/panorama/{n}` applies the same visibility checks as `model`. For spot tours only, it looks up spot `n` in `result.spots` and returns `env.UPLOADS.get(modelKey, { range: { offset, length } })` as `Content-Type: image/jpeg` with `Cache-Control: private, no-store`. It returns 404 for an unknown spot or a splat tour. Extend the route regex with `|panorama/(\d{1,2})`.
- [ ] **Step 1: Write the failing tests.**
  - In `tests/spot-tour.test.ts`: `accepts a valid result`, `rejects zero or nine spots`, `rejects overlapping or out-of-bundle ranges`, `rejects unaligned offsets`, `drops extra fields`.
  - In `tests/room-tour.test.ts`: `create caps splat at 64 MB and spots at 96 MB`, using `tests/sqlite-d1.ts`.
  - In `tests/tours-runtime.py`: extend the synthetic flow with a spots tour. Upload a small archive, claim (assert `kind == 'spots'`), complete with a two-spot bundle, then fetch `panorama/0` as the owner (bytes equal the first JPEG), as a stranger before publish (404/403 as `model` does), and after publish (200). Splat tours get 404 on `panorama/0`.
- [ ] **Step 2: Run and see them fail.** Run `npx vitest run tests/spot-tour.test.ts tests/room-tour.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** Store `kind` on the row and expose it in `view()`.
- [ ] **Step 4: Run the tests.** Run `npm run typecheck && npm test`, then the runtime test as in `.github/workflows/iphone.yml` (start the isolated API on 8936, apply migrations including 0020, then `API_BASE=http://127.0.0.1:8936 TOUR_PROCESSOR_TOKEN=isolated-synthetic-tour-test-token-64-characters-only python3 tests/tours-runtime.py`). Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add the spots tour kind, its result contract and per-spot panorama access"`

### Task 8: Pick mesh views from a candidate list

**Files:**
- Modify: `processing/room_mesh.py` (`build_mesh(..., candidates: list[int] | None = None)`; `select_views(count, limit, candidates=None)`)
- Test: `tests/room-mesh-unit.py`

**Interfaces:**
- Produces: `select_views(count: int, limit: int = MAX_VIEWS, candidates: list[int] | None = None) -> list[int]`, which spreads evenly over `candidates` when given. `build_mesh(frames_dir, out_dir, model_name=MODEL, log=print, candidates=None) -> dict`.
- [ ] **Step 1: Write the failing test.** `test_candidates_restrict_and_spread`: `select_views(200, 60, candidates=list(range(0, 200, 2)))` has length 60 and only even indices, and includes the first and last candidates.
- [ ] **Step 2: Run and see it fail.** Run `/tmp/room-mesh/bin/python tests/room-mesh-unit.py` (or any environment with NumPy). Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS, including the existing view-selection tests.
- [ ] **Step 5: Commit.** `git commit -m "Let the room mesh choose views from a candidate list"`

### Task 9: Panorama stitcher

**Files:**
- Create: `processing/spot_stitch.py`
- Create: `processing/requirements-spots.txt` (`numpy`, `opencv-python-headless`, `scipy`, each pinned to the versions installed when the task runs)
- Test: `tests/spot-stitch-unit.py`

**Interfaces:**
- Produces:
  - `@dataclass class Slice: path: Path; K: np.ndarray (3×3); R: np.ndarray (3×3 camera-to-world rotation, OpenCV camera axes); width: int; height: int`
  - `load_spot_slices(manifest: dict, root: Path) -> dict[int, list[Slice]]`. It uses only `manifest['spots'][*]['slices']`, rejects any path not matching `images/\d{5}\.jpg` or escaping `root` (`ValueError('capture_invalid')`), and converts the ARKit transform with the existing `FLIP` convention from `room_mesh.py`.
  - `refine_rotations(slices: list[Slice], max_correction_deg: float = 3.0) -> list[np.ndarray]`. It uses ORB features (2000 per image), matches pairs whose optical axes are within 70°, and minimises the angular error of matched rays with `scipy.optimize.least_squares` over per-slice axis-angle deltas. The first slice is fixed. Corrections are clamped to `max_correction_deg`, and on failure (fewer than 20 inliers overall) it returns the input rotations.
  - `exposure_gains(slices, rotations) -> np.ndarray`: per-slice gains from least squares on mean luminance in pairwise overlaps, normalised to mean 1.
  - `stitch(slices: list[Slice], width: int = 4096) -> tuple[np.ndarray, float]`. It returns `(equirect_bgr_uint8, hole_fraction)`. For each output direction it blends every slice that sees it, weighted by feathering (distance to the nearest image border, squared). Below −80° pitch with no coverage it fills the neutral nadir disc (BGR `(43, 43, 43)`, 2° feathered edge). Any other uncovered pixels are filled with `cv2.inpaint(…, cv2.INPAINT_TELEA)`, and `hole_fraction` counts them (nadir excluded).
  - `MAX_HOLES = 0.02`: callers fail a spot whose `hole_fraction` is above this.
  - Equirect convention as in Global Constraints: column `u = (yaw / 2π + 0.5) * width`, where yaw = `atan2(d.x, -d.z)`, and row `v = (0.5 - pitch / π) * height`.
- [ ] **Step 1: Write the failing tests** (synthetic, no device data).
  - The fixture renders a procedural test sphere (checkerboard + colour gradient) into 29 slices at `SpotLayout`-equivalent rotations, 1440 × 1080, with fx = 1100.
  - `test_stitch_recovers_sphere`: stitching with the true rotations gives PSNR ≥ 30 dB against the ground-truth equirect above −80° pitch, and `hole_fraction == 0`.
  - `test_refinement_fixes_pose_noise`: 1.5° random rotation noise gives PSNR ≥ 26 dB after refinement and strictly higher than without it.
  - `test_exposure_gains_equalise`: brightening one slice by 1.3× produces a gain within 0.05 of 1/1.3 for it.
  - `test_rolled_slices_stitch`: rolling every slice 20° gives the same PSNR bound.
  - `test_missing_ring_reports_holes`: dropping ring 1 gives `hole_fraction > MAX_HOLES`.
  - `test_ignores_slices_of_unfinished_spots`: a manifest whose frames include slices tagged spot 2, with spot 2 absent from `spots`, yields only spot 1.
  - `test_rejects_escaping_paths`.
- [ ] **Step 2: Run and see them fail.** Run `python3 -m venv work/spots-venv && work/spots-venv/bin/pip install -r processing/requirements-spots.txt && work/spots-venv/bin/python tests/spot-stitch-unit.py`. Expected: FAIL, import error.
- [ ] **Step 3: Implement `spot_stitch.py`.** Vectorise the per-pixel loop with NumPy over row blocks of 256, so a 4096 × 2048 spot stitches in under 60 s on the Mac mini.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Add the test to CI.** In `.github/workflows/checks.yml`, after the room-mesh test, install `processing/requirements-spots.txt` into a venv and run `tests/spot-stitch-unit.py`.
- [ ] **Step 6: Commit.** `git commit -m "Stitch spot slices into equirectangular panoramas with rotation and exposure refinement"`

### Task 10: Worker path for spot tours

**Files:**
- Modify: `processing/tour_worker.py` (dispatch on `job['kind']`; `reconstruct_spots(capture, work)`; bundle writer; `LIMIT` by kind)
- Test: `tests/tour-processor-unit.py`

**Interfaces:**
- Consumes: `spot_stitch.load_spot_slices`, `stitch` and `MAX_HOLES` (Task 9), `room_mesh.build_mesh(candidates=…)` (Task 8), and the API contract (Task 7).
- Produces:
  - `SPOT_LIMIT = 96 * 1024 * 1024`
  - `extract_capture(capture: Path, out: Path) -> dict`: reads the USTAR safely (regular files only, names from `CaptureArchive.isCaptureName`'s set, no links, total ≤ limit) and returns the parsed `manifest.json`.
  - `reconstruct_spots(capture, work)`:
    - Extract, then stitch each spot and write `panos/NN.jpg` at quality 85.
    - A spot over `MAX_HOLES` raises `ValueError('spot_incomplete')`.
    - Positions come from `SpotRecord.position` and `floor_y`.
    - Build the mesh when `CUSE_ROOM_MESH=1`, with candidates = every walk frame plus every level-ring slice. It is optional, exactly like `build_optional_mesh`.
    - Write `result/spots.bundle` (USTAR: `spots.json`, then `panos/00.jpg`, …), recording each panorama's data offset and length, and write `result/display.json` matching `SpotTourResult`.
  - `process_job` sends the bundle to `complete` for spot jobs. The mesh upload is unchanged. The failure codes gain `'spot_incomplete'` in the forwarded list.
- [ ] **Step 1: Write the failing tests.**
  - `test_bundle_offsets_point_at_jpegs`: build a bundle from two tiny JPEGs. For each spot, `bundle[offset:offset+length]` starts with `FFD8` and equals the source bytes.
  - `test_extract_rejects_links_and_unknown_names`.
  - `test_spot_job_dispatch`: with a stubbed API and stubbed `reconstruct_spots`, a `kind: 'spots'` job uploads `spots.bundle` and the display metadata.
  - `test_spot_incomplete_is_forwarded`.
- [ ] **Step 2: Run and see them fail.** Run `python3 tests/tour-processor-unit.py`. Expected: FAIL.
- [ ] **Step 3: Implement.** Splat jobs keep the current code path byte for byte.
- [ ] **Step 4: Run the tests.** Run `python3 tests/tour-processor-unit.py`. Expected: PASS. Then run an end-to-end synthetic job: extend `processing/make_synthetic_capture.py` with `--spots`, which writes a version 2 archive from the Task 9 fixture renderer, and run `processing/tour_worker.py --once` against the isolated API from Task 7. Expected: the tour is `ready`, and `panorama/0` returns a 4096 × 2048 JPEG.
- [ ] **Step 5: Commit.** `git commit -m "Process spot tours into stitched panoramas, a bundle and an optional mesh"`

---

## Phase D: Viewer

### Task 11: Spot viewer math

**Files:**
- Create: `src/spot-viewer-math.ts`
- Test: `tests/spot-viewer-math.test.ts`

**Interfaces:**
- Produces:
  - `export const CIRCLE_RANGE = 6` and `export const PICK_RADIUS = 0.35`
  - `export function nearbySpots(current: TourSpot, spots: TourSpot[]): TourSpot[]`: the other spots within 6 m horizontally, nearest first.
  - `export function floorHit(eye: Vec3, dir: Vec3, floorY: number): Vec3 | null`: null for rays at or above the horizon.
  - `export function pickSpot(hit: Vec3, candidates: TourSpot[]): TourSpot | null`: the nearest within `PICK_RADIUS`, otherwise null.
  - `export function lookDirection(yaw: number, pitch: number): Vec3`: the same yaw convention as the equirect.
  - `export function clampPitch(p: number): number`: limited to ±85°.
  - `export function overviewBounds(spots: TourSpot[], mesh: TourMesh | null): { center: Vec3; size: number }`
  - `type Vec3 = [number, number, number]`
- [ ] **Step 1: Write the failing tests.** Cover range filtering and order, a downward ray hitting the floor at the expected point, a ray at the horizon giving null, picking within or just outside 0.35 m, yaw 0 giving `[0, 0, -1]`, a pitch clamp, and bounds falling back to the spots when the mesh is null.
- [ ] **Step 2: Run and see them fail.** Run `npx vitest run tests/spot-viewer-math.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add spot viewer geometry helpers"`

### Task 12: The spot viewer and wiring it into the web and the app

**Files:**
- Create: `src/SpotViewer.tsx`, `src/spot-viewer.css`
- Modify: `src/RoomTours.tsx` and the `/tour-viewer` branch in `src/main.tsx` (choose `SpotViewer` when `tour.kind === "spots"`, otherwise `SplatViewer`)
- Modify: `ios/CuseSublets/RoomToursView.swift` (upload body adds `"kind": "spots"` for spot takes; the intro copy changes to `"Capture a few spots in each room. Viewers look around a 360° photo at each spot."`; the owner review before publish opens the viewer)
- Modify: `ios/CuseSublets/Models.swift` (`RoomTour.kind: String`, defaulting to `"splat"` when absent)
- Test: `tests/booking-ui.test.ts`-style render test → `tests/spot-viewer.test.ts` (the component renders the mode buttons and fetches `panorama/{first}` first), and `ios/CuseSubletsTests/ModelsTests.swift` (`RoomTour` decodes without `kind` as splat)

**Interfaces:**
- Consumes: `SpotTourResult` and `TourSpot` (Task 7), the math (Task 11), and the existing mesh endpoint `/api/listings/{l}/tours/{t}/mesh` (coloured PLY, ARKit world).
- Produces: `export default function SpotViewer({ tour }: { tour: RoomTour })`.
- Behaviour:
  - **Walk mode** (default). The camera sits at `spot.position` with `y` = position y. A sphere mesh with inward-facing normals, radius 50, is textured with the current panorama. Drag changes yaw and pitch, clamped. Each nearby spot gets a ring (a torus or textured disc of radius 0.3 m) at its `[x, floorY + 0.01, z]`. A tap uses `floorHit` and `pickSpot`, then moves.
  - **Panoramas.** Fetch them lazily from `panorama/{n}` with `credentials: "same-origin"`. Prefetch the nearby spots' panoramas after the current one loads.
  - **Moving.** Over 600 ms, ease the camera to the new spot while the mesh (if loaded) renders and the old sphere fades out. Then fade the new sphere in. Without a mesh, crossfade the spheres only.
  - **Plan mode.** An orthographic top-down camera fitted by `overviewBounds`, showing the mesh (if any) and numbered markers. A tap on a marker enters Walk mode at that spot.
  - **3D mode.** A perspective orbit at a 45° elevation around the same centre, with the same markers.
  - **Controls.** Buttons labelled exactly `3D`, `Plan` and `Walk`, plus the hint `"Drag to look around. Tap a circle on the floor to move there."`, shown until the first move.
  - **Errors.** A panorama that fails to load shows `"This spot couldn't load. Try another spot."` and keeps the markers usable. No mesh hides the 3D button.
- [ ] **Step 1: Write the failing tests** (the vitest render test and `ModelsTests`).
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.** Follow `SplatViewer.tsx` for the PlayCanvas setup, `ResizeObserver`, disposal and the abort-on-unmount pattern.
- [ ] **Step 4: Run the checks.** Run `npm run typecheck && npm test && npm run build`, then the iOS unit tests. Expected: PASS. Manually run the Task 10 synthetic ready tour in the dev server: open `/tour-viewer?…` for it, then drag, tap a circle and switch modes.
- [ ] **Step 5: Commit.** `git commit -m "Add the Street View-style spot viewer for spot tours"`

---

## Phase E: Device tuning, docs, PR

### Task 13: Tune on the iPhone 17 and document

**Files:**
- Modify: `ios/CuseSublets/SpotTurn.swift` (the layout and tolerance constants, if tuning changes them)
- Modify: `docs/mobile/photographic-tours.md` (a new "Spot tours" section covering capture, limits, processing, viewer and privacy; the existing splat text is kept and labelled "Walk-around tours (development comparison)")
- Modify: `docs/mobile/iphone-17-test-guide.md` (spot capture steps)
- Create: `docs/mobile/spot-capture-device-results.md`

- [ ] **Step 1: Run a device check.** Install the Cuse Capture Test build on the iPhone 17 and capture a bedroom with 4–6 spots in the Device capture check's Spot capture section. Record:
  - the time per spot
  - the ceiling, floor and nadir result in `SpotPreview`
  - whether any dot was hard to hold
  - tracking losses
  - the final coverage percentage against your own judgement
  - the archive size
- [ ] **Step 2: Tune.** Adjust `SpotLayout.standard` (ring pitches and counts), `alignTolerance` and `holdDuration` only on evidence from Step 1, rerun `SpotTurnTests` (update the count test if the layout changes), and repeat Step 1 once.
- [ ] **Step 3: Process the device take.** Export the archive and run the worker locally against the isolated API with `CUSE_ROOM_MESH=1`. Record the per-spot `hole_fraction`, the stitch time, the mesh time, and the visible seams (with screenshots in `docs/mobile/screenshots/spot-*.png`; keep them free of personal details).
- [ ] **Step 4: Write the docs and results file** with the measured numbers. State plainly what remains unverified.
- [ ] **Step 5: Commit and push.** `git commit -m "Tune spot capture on iPhone 17 and document spot tours" && git push`

### Task 14: Pull request

- [ ] **Step 1: Run every check in the CI workflows locally.** That covers typecheck, vitest, the Python unit tests including spot stitching, build, the tours runtime and both iOS schemes. Expected: all pass.
- [ ] **Step 2: Open a PR** from `feat/spot-tours` into `feat/iphone-app` (the iPhone app isn't on `main` yet). Its body covers the problem, the new behaviour, validation with device results, and risks (monocular depth, handheld parallax seams, the unproven mesh quality with fewer walk frames, and the 96 MiB limit's dependence on the Workers plan). No AI attribution.
- [ ] **Step 3: Wait for the PR checks to be green, then hand back to the owner.** Merging is the owner's call.
