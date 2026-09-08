# Reality Git Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Repository instructions map subagent work to sequential execution in the main session.

**Goal:** Build and validate the approved one-object AR diff prototype on iPhone 15 Pro, including captured Gaussian appearance and live Astra re-identification.

**Architecture:** The iPhone owns geometry, reference state, and rendering. A nearby Mac continuously assists with Vision localization, runs an existing Gaussian trainer on calibrated captures, and makes less frequent Astra requests. Shared Swift value types connect the two; no database, job broker, or cloud deployment.

**Tech Stack:** Swift, SwiftUI, ARKit, RealityKit, Vision, URLSession; a macOS Swift executable with Vapor 4 for HTTP; iOS 27 native RealityKit splats first after toolchain upgrade; MetalSplatter/Metal as fallback.

**Spec:** [Approved design](../specs/2026-09-08-reality-git-design.md)

## Global Constraints

- Support one object, one room, and one uninterrupted AR session.
- Use Swift, ARKit, RealityKit, and Vision on the phone.
- Add Metal only if the chosen splat renderer requires it.
- Exclude accounts, full-room reconstruction, history browsing, cross-session persistence, multiple simultaneous objects, and rotation-only diffs.
- No manual commit step is required.
- Observations never automatically replace that reference.
- Rendering and local tracking continue without waiting for networking.
- Older results may contribute identity evidence but cannot overwrite a newer accepted position.
- Simulator or mocked checks do not substitute for camera, LiDAR, anchor stability, splat alignment, and responsiveness checks on the phone.

## Starting point and choices

The repository contains documentation only. Verified updated environment: Apple Silicon, selected Xcode 27.0 beta 6 (27A5252f), iOS SDK 27.0. GaussianSplatComponent is present in the installed RealityFoundation Swift interface. Target iOS 27 for the native splat prototype; the user is installing iOS 27 beta 8 on the iPhone, with completion not yet verified. Use macOS 14 as the server baseline unless the selected trainer requires a higher version. Device signing and live Astra access must be verified during execution, not assumed from this environment.

Keep one integrated plan because the Mac and phone jointly implement a single interaction. Every task below has its own testable result and commit. Code blocks define essential contracts or algorithms, not complete framework boilerplate. Read the installed SDK declarations before implementing framework calls.

Research update (September 8): read [the component review](../../research/2026-09-08-reusable-components.md) before selecting dependencies. Evaluate Brush first and msplat v1.1.4 second for trained appearance; retain depth-initialized Gaussians as a preview/fallback. Current Brush code has an open regression report on AMD/Linux, so compare it with v0.3.0 on our Mac before pinning. All compatibility and performance checks remain unrun.

Keep Vision as the baseline. After task 3, compare real temporal EdgeTAM on the Mac using Transformers' streaming implementation. The existing Core ML example is image segmentation, and the full temporal export remains an open PR. A Python worker is conditional on measured benefit; the Swift server remains the baseline. Do not raise the phone's OS minimum for an unproven wrapper.

## File map

- `ios/RealityGit.xcodeproj`: native app, shared RealityGit scheme, local core package dependency.
- `ios/RealityGit/App/`: SwiftUI entry, camera screen, session coordinator.
- `ios/RealityGit/AR/`: AR session, immutable frame extraction, depth projection.
- `ios/RealityGit/Tracking/`: local Vision tracking, selection, reference visibility.
- `ios/RealityGit/Networking/`: bounded frame buffer and Mac client.
- `ios/RealityGit/Capture/`: guided capture and upload.
- `ios/RealityGit/Rendering/`: RealityKit proxy scene and later splat overlay.
- `Packages/RealityGitCore/`: shared models, pure reconciliation, wire contracts and tests.
- `server/`: macOS Swift package; HTTP routes, Vision worker, dataset export/trainer process, Astra adapter.
- `docs/testing/device-validation.md`: observed results and tuning, explicitly distinguishing unrun checks.
- `docs/integrations/astra.md`: verified provider contract and access requirements.

## Verification conventions

Core: `swift test --package-path Packages/RealityGitCore`.
Server: `swift test --package-path server`.
App compile: `xcodebuild -project ios/RealityGit.xcodeproj -scheme RealityGit -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
No simulator runtime is required. The unsigned generic-device build checks compilation only; running on the phone requires signing. Device: select the actual connected iPhone and available signing team in Xcode. Do not invent a device ID or team. Each task ends with staging only its files and a descriptive commit. Do not run implementation during planning.

### Task 1: Stable camera view and world anchor

**Files:** Create `ios/RealityGit.xcodeproj`, `ios/RealityGit/Info.plist`, `ios/RealityGit/App/RealityGitApp.swift`, `ios/RealityGit/App/CameraScreen.swift`, `ios/RealityGit/AR/ARSessionController.swift`, `docs/testing/device-validation.md`; update `.gitignore`.

**Interface:** `@MainActor final class ARSessionController` owns `ARView`, exposes `start()`, `reset()`, and published tracking status. One ARSession for the entire app.

- [x] Create the native app target and shared scheme. Add camera usage text; ignore Swift build directories and local signing settings. Keep signing credentials out of git.
- [x] Configure capability checks and depth:

```swift
let configuration = ARWorldTrackingConfiguration()
guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
    return // Present “This prototype requires LiDAR scene depth.”
}
configuration.frameSemantics.insert(.sceneDepth)
arView.session.run(configuration)
```

- [x] Add a temporary test cube anchored one meter along the camera's viewing direction after tracking becomes normal. Show permission denial and unavailable depth as visible states.
- [ ] Build with the app command above. On iPhone, walk around the cube, interrupt the session, and confirm tracking status changes. Record whether its position remains stable. No automated test for SwiftUI scaffolding.
- [x] Commit as `feat: establish AR session and stable test anchor`.

**Execution status:** Generic-device Debug build passes. Physical checks remain pending; task 1 is not yet device-validated.

### Task 2: Select an object and obtain metric observations

**Files:** Create `Packages/RealityGitCore/Package.swift`, `Sources/RealityGitCore/Models.swift`, `Sources/RealityGitCore/Projection.swift`, `Tests/RealityGitCoreTests/ProjectionTests.swift` under that package; create `ios/RealityGit/Tracking/ObjectSelector.swift`, `LocalObjectTracker.swift`, `ios/RealityGit/AR/FrameExtractor.swift`; modify CameraScreen.

**Interfaces:** `ObjectSelector` produces a normalized image rectangle. `LocalObjectTracker.start(rect:image:)` seeds Vision; `observe(image:)` returns a rectangle and confidence or nil. `Projection.unproject(u:v:depth:fx:fy:cx:cy:) -> SIMD3<Float>` returns ARKit camera coordinates. All frame images use one documented upright orientation; intrinsics and image/depth mappings must follow that transform.

- [ ] Define value types for observations and add the geometry test before implementing projection:

```swift
// Shared models; UUID fields identify the selected object and AR coordinate session.
struct ObservationKey: Codable, Equatable, Sendable {
    let sessionID: UUID
    let objectID: UUID
    let frameID: UInt64
    let captureTime: Double
}
// ProjectionTests
func testOpticalCenterFacesNegativeZ() {
    let p = Projection.unproject(u: 320, v: 240, depth: 2,
                                fx: 500, fy: 500, cx: 320, cy: 240)
    XCTAssertEqual(p, SIMD3<Float>(0, 0, -2))
}
```

- [ ] Run core tests and observe the missing implementation failure. Implement camera projection and test an off-center pixel plus rejection of nonfinite/nonpositive depths at the caller:

```swift
return SIMD3((u - cx) * depth / fx, -(v - cy) * depth / fy, -depth)
```

- [ ] Implement tap-to-select using a foreground instance mask; allow a drawn rectangle to disambiguate or recover from no mask. Use `VNGenerateForegroundInstanceMaskRequest` and `VNTrackObjectRequest` after inspecting their SDK APIs. Do not silently choose an unrelated foreground instance.
- [ ] Copy only needed buffers off the AR callback and serialize Vision work with at most one pending image. Use masked depth samples, depth confidence, and robust median position; do not use the rectangle's background as object depth. If segmentation is unavailable, show uncertain depth rather than accepting contaminated geometry.
- [ ] Apply the matching frame's camera transform to camera-space points. Test image corner transformations at portrait/landscape orientations and different depth resolutions. Run core tests and compile the app.
- [ ] On the phone select and follow a stationary object while moving the camera. Record world-position stability, then commit `feat: select and locate one object with Vision and depth`.

### Task 3: Continuous Mac tracking assistance

**Files:** Create `Packages/RealityGitCore/Sources/RealityGitCore/WireModels.swift`, `server/Package.swift`, `server/Sources/RealityGitServer/main.swift`, `Routes.swift`, `VisionWorker.swift`, `server/Tests/RealityGitServerTests/RouteTests.swift`, `ios/RealityGit/Networking/AssistantClient.swift`, `FrameBuffer.swift`; update Info.plist and CameraScreen.

**Interfaces:** Shared Codable `FrameRequest` has key, upright JPEG Data, optional seed rectangle `[Double]` in top-left normalized x/y/width/height, and reference flag. `DetectionReply` has the same key, optional rectangle, confidence, and candidate identifier. Matrices/depth remain in the phone buffer for live localization. Capture uploads later carry full calibration. `AssistantClient.submit(_:) async throws -> DetectionReply`. `FrameBuffer` indexes immutable geometry by ObservationKey.

- [ ] Add a Vapor 4 executable and test target, pin resolved dependencies, and expose `GET /health` and `POST /observe`. Use Codable DTOs shared through the local package and adopt Vapor Content in the server target only.
- [ ] Test rejection of oversized input and malformed rectangles, and exact observation-key echo:

```swift
let key = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 42, captureTime: 1)
let request = FrameRequest(key: key, jpeg: fixtureJPEG, seedRect: [0.2,0.2,0.3,0.3], isReference: true)
let reply = try await worker.observe(request)
XCTAssertEqual(reply.key, key)
```

Here `fixtureJPEG` is a checked-in tiny synthetic image and `worker` is the VisionWorker instance under test; use a deterministic injected localization closure for route tests, not a claim of real Vision accuracy.
- [ ] Implement `VisionWorker.observe(_:) async throws -> DetectionReply` on a dedicated serial worker off HTTP event loops. Continue the selected track; when lost, enumerate foreground candidates and compare Vision feature prints against the reference crop. Return uncertainty for ambiguous candidates; live Astra acceptance arrives in task 10.
- [ ] Start at 2 samples/second and a 640-pixel long edge; allow configuration. One in-flight request plus one replaceable pending observation. Bound source buffers to 12 sampled frames and expire after 5 seconds. Use a 3-second observation timeout; do not retry obsolete frames.
- [ ] Add a manually entered Mac address, local network usage description, and narrowly scoped development local-network transport configuration. Limit server observation bodies to 4 MB; bind to LAN only when explicitly launched for phone use. No accounts or Internet deployment.
- [ ] Record a short clip with occlusion, camera movement and a lookalike. Compare baseline Vision with temporal EdgeTAM on the Mac before choosing an enhanced worker. Verify MPS execution, bounded streaming memory and source-frame IDs; keep Vision if the candidate fails or adds no measurable benefit. Record results in `docs/testing/tracker-comparison.md`. Do not substitute repeated fixed-point segmentation for temporal propagation.
- [ ] Run server tests, core tests, and app build. On the phone verify repeated Mac detections and continued local tracking after stopping the server. Commit `feat: add continuous Mac vision assistance`.

### Task 4: Immutable reference and ordered reconciliation

**Files:** Create core `ReferenceState.swift`, `Reconciler.swift`, `Tests/RealityGitCoreTests/ReconcilerTests.swift`; create `ios/RealityGit/App/SessionCoordinator.swift`; update ARSessionController and AssistantClient.

**Interfaces:** `ReferenceState` stores object/session identity, reference transform, bounds and appearance reference. `PositionObservation` stores key, `position: SIMD3<Float>`, `identityConfirmed: Bool`, `confidence: Float`. `Reconciler.init(referencePosition:sessionID:objectID:)`; `accept(_:) -> Bool`; `currentPosition: SIMD3<Float>?`; `referencePosition: SIMD3<Float>`.

- [ ] Add a failing ordering test with explicit construction:

```swift
let session = UUID(), object = UUID()
var r = Reconciler(referencePosition: .zero, sessionID: session, objectID: object)
let newer = PositionObservation(key: .init(sessionID: session, objectID: object, frameID: 20, captureTime: 2), position: [1,0,0], identityConfirmed: true, confidence: 1)
let older = PositionObservation(key: .init(sessionID: session, objectID: object, frameID: 10, captureTime: 1), position: [2,0,0], identityConfirmed: true, confidence: 1)
XCTAssertTrue(r.accept(newer))
XCTAssertFalse(r.accept(older))
XCTAssertEqual(r.currentPosition, SIMD3<Float>(1,0,0))
XCTAssertEqual(r.referencePosition, .zero)
```

- [ ] Run the failing test. Implement monotonic source ordering, finite geometry checks, session/object matching, and immutable reference. Allow a same-frame server correction only if it improves source priority/confidence; it must not increment independent confirmation counts.
- [ ] Integrate local and Mac results through SessionCoordinator. Recover source calibration only from FrameBuffer. Missing source means discard positional result. Keep server candidate identity unresolved after track loss until confirmed.
- [ ] Test mismatched sessions, duplicate local/server reports, expired frames, and reset invalidation. Reset cancels requests, replaces session ID, clears reference, and drops previous jobs.
- [ ] Run core tests and app build; commit `feat: preserve reference and reconcile ordered observations`.

### Task 5: Confirm changes and render proxies

**Files:** Create core `DiffState.swift`, `DiffReducer.swift`, `Tests/RealityGitCoreTests/DiffReducerTests.swift`; create iOS `Tracking/ReferenceVisibility.swift`, `Rendering/DiffRenderer.swift`; update SessionCoordinator and CameraScreen.

**Interfaces:** `DiffState: unchanged, moved, absent`; confidence tracked separately. `VisibilityEvidence: unknown, occluded, visibleEmpty, visibleOccupied`. `DiffReducer.observe(position: SIMD3<Float>?, identityConfirmed: Bool, visibility: VisibilityEvidence, time: Double)` updates `state`; `DiffRenderer.update(reference:current:showRed:showGreen:)` consumes accepted state.

- [ ] Add tests before implementation:

```swift
var diff = DiffReducer(referencePosition: .zero)
for i in 0..<10 {
    diff.observe(position: nil, identityConfirmed: false, visibility: .occluded, time: Double(i))
}
XCTAssertEqual(diff.state, .unchanged)
for i in 10..<20 {
    diff.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: Double(i))
}
XCTAssertEqual(diff.state, .absent)
```

- [ ] Implement initial calibration defaults: move beyond 15 cm, restore within 8 cm; require three independent source observations spanning at least 0.5 seconds. Require visible-empty evidence spanning 1 second. Reset confirmation sequences on contradictory or unknown evidence. Test jitter, partial restoration, deduplication and confirmed-move/current-unknown separately.
- [ ] Build visibility evidence by projecting reference bounds, checking that the region is in-frame, and comparing confident live depth to captured reference surface samples. Closer surfaces mean occluded; missing depth means unknown. A detector miss alone is insufficient. Accept empty only with repeated unoccluded region checks and negative local/Mac evidence.
- [ ] Render reference red at 25% opacity and current green at 25% using RealityKit boxes sized to captured bounds. Keep red after a confirmed move when current tracking is lost; hide green on stale/uncertain location. Hide all overlays while AR tracking is unreliable. Resume only in the retained coordinate frame; provide recapture after failed recovery.
- [ ] Run core tests and app build. Physically verify visible movement, turn-away movement, occlusion, removal, and position-based restoration. Record tuned thresholds, then commit `feat: display confirmed object diffs with visibility checks`.

### Task 6: Guided calibrated capture

**Files:** Create core `CaptureManifest.swift`, iOS `Capture/CaptureCoordinator.swift`, `CaptureUploader.swift`, server `CaptureStore.swift`, and server test `CaptureStoreTests.swift`; modify Routes and CameraScreen.

**Interfaces:** `CaptureManifest` carries session/object IDs, capture ID, reference transform, bounds and an array of `CaptureFrame` entries. Each entry has frame key, image dimensions, column-major 3x3 intrinsics, column-major 4x4 camera-to-world matrix, JPEG path, binary mask path, depth dimensions, and float32 little-endian metric depth path. Saved images/masks/calibration share the documented orientation. Assets are named by server-generated IDs, never arbitrary client filesystem paths.

- [ ] Implement guided stationary-object capture targeting 20 accepted views and at least 30 degrees of viewing-direction spread. These are initial quality thresholds, not a promised capture duration. Reject blurred, missing-depth, lost-mask, or moving-object frames. Show progress and recapture for insufficient views.
- [ ] Store frames incrementally; cap at 40 views, each with RGB at most 1280 pixels long edge and native depth resolution. Reference pose/bounds remain frozen. Start normal tracking after capture finalization while upload/reconstruction runs separately.
- [ ] Add `POST /captures` to create an ID, `PUT /captures/:id/frames/:frameID` for a bounded frame payload, and `POST /captures/:id/finish` with the manifest. Keep each upload at most 16 MB, total capture at most 128 MB, and one active capture job. Rescale intrinsics with any image resizing.
- [ ] Test rejected calibration and wrong-session finalization before implementing validators:

```swift
XCTAssertThrowsError(try CaptureValidator.validate(depth: [Float.nan], width: 1, height: 1))
XCTAssertThrowsError(try CaptureValidator.validate(depth: [1], width: 2, height: 2))
```

Define `CaptureValidator.validate(depth: [Float], width: Int, height: Int) throws`; invalid depth pixels may be represented by zero and skipped, but nonfinite serialized data and size mismatches are rejected. Reject nonfinite matrices and invalid file identifiers as well.
- [ ] Run tests and device capture. Inspect a saved image/mask/depth trio for alignment; commit `feat: capture calibrated object views for reconstruction`.

### Task 7: Train object appearance with an existing Mac engine

**Files:** Create server `Reconstruction/NerfstudioExporter.swift`, `TrainerProcess.swift`, `ReconstructionJob.swift`, tests `NerfstudioExporterTests.swift`, `TrainerProcessTests.swift`, and `docs/testing/trainer-comparison.md`; modify Routes.

**Interfaces:** `NerfstudioExporter.export(manifest: CaptureManifest, root: URL) throws -> URL` returns a trainer dataset directory. `TrainerProcess.run(dataset: URL, output: URL) async throws -> URL` runs one pinned local trainer and returns its PLY. Job status is queued/running/ready/failed with capture/session/object IDs, asset URL, bounds, and an explicit asset-to-object transform.

- [ ] Export calibrated RGBA views, a masked metric seed PLY, and `transforms.json`. Transform camera poses and seed points into the same object-local frame. Store any further trainer normalization in output metadata. Never mix Swift column-major arrays with Nerfstudio's nested row arrays:

```swift
let rows: [[Float]] = (0..<4).map { row in
    (0..<4).map { column in objectFromCamera[column][row] }
}
// objectFromCamera = inverse(referenceTransform) * cameraToWorld
// transforms.json: frames[].transform_matrix = rows
// frames[] also carries file_path, w, h, fl_x, fl_y, cx, cy.
// ply_file_path points to the metric seed cloud in the same frame.
```

- [ ] Write exporter tests before implementation: two views of the same world point produce identical object-local seed positions; resizing scales intrinsics; transparent pixels do not seed points. Run core/server tests and confirm failures before adding the exporter.
- [ ] Evaluate pinned Brush v0.3.0 and reviewed current commit `5a9d4cfaa9c4e167924fbed586e6def3fa20433b` on one identical capture. Inspect `brush --help` for that revision's actual training/export flags and record the exact command. Compare mask semantics, usable asset time, memory, silhouette, background leakage and metric alignment. Repeat one run. The newer revision is not automatically preferred.
- [ ] If Brush fails the capture/alignment check, evaluate msplat v1.1.4 (`6b819711fa7c90f054567cb4fb4937743367afdd`) using its documented C++ CLI. Inspect mask/alpha loss behavior and preserve or invert `autoScaleAndCenter`; output in meters must be demonstrated, not assumed. Record the exact passing revision and command. Do not build both trainers into the product; retain one chosen process adapter.
- [ ] Run the trainer using Foundation Process with an argument array, one reconstruction at a time, bounded logs and cancellation. Keep work off the Vision/HTTP executors. Test nonzero exit, cancellation, missing/invalid output, and wrong-session completion using a tiny deterministic fixture process. Invoke it without shell interpolation:

```swift
let process = Process()
process.executableURL = executableURL
process.arguments = validatedArguments
try process.run()
// Drain stdout/stderr concurrently, cap retained log text,
// await termination asynchronously, then validate exit status and PLY.
```

- [ ] Add `GET /captures/:id/status` and `GET /captures/:id/asset`. Validate finite asset coordinates, bounds and splat budget. Invalidate old-session jobs and clean temporary captures on reset or 30-minute idle expiry. If no trainer passes, retain the geometric proxy and report the failed milestone; depth Gaussians may be used as an explicitly approximate preview, not a reason to claim trained appearance works.
- [ ] Verify the chosen output in a splat viewer, run exporter/process tests, and commit `feat: train captured object appearance with a pinned Mac engine`.

### Task 8: Render aligned red Gaussian ghosts

**September 8 update:** The user is willing to install iOS 27. Before the MetalSplatter steps below, verify completion of iOS 27 installation on the device (Xcode 27 and its SDK are now verified), then test `GaussianSplatComponent` with a small known asset. Populate its buffers using the documented GaussianSplatResource API; verify red color, opacity, metric scale and anchored camera motion. If this succeeds, implement SplatOverlay using a RealityKit entity and skip the separate Metal renderer steps. Use an iOS 27 deployment target for that prototype. The iOS deployment target is now 27; the Mac toolchain is verified and the phone upgrade is in progress. Retain MetalSplatter as the fallback if the native test fails. Record the selected path and actual OS/SDK in the alignment report.

**Files:** Create iOS `Rendering/SplatOverlay.swift`, `SplatAssetLoader.swift`; modify CameraScreen, DiffRenderer and project package dependencies; add `docs/testing/splat-alignment.md`.

**Interface:** `SplatOverlay.load(assetURL: URL, referenceTransform: simd_float4x4) async throws`; `setVisible(_:)`; `updateCamera(frame: ARFrame, viewport: CGSize, orientation: UIInterfaceOrientation)`.

- [ ] Inspect and pin MetalSplatter's current source/sample and license. First load the task-7 asset in its renderer. Verify PLY field semantics before integrating with AR.
- [ ] Add a transparent Metal overlay above ARView; ARView remains the sole camera/session owner. Drive the splat view/projection from the same ARFrame and viewport/orientation as the camera view. Essential transform:

```swift
let modelView = frame.camera.viewMatrix(for: orientation) * referenceTransform
let projection = frame.camera.projectionMatrix(for: orientation,
    viewportSize: viewport, zNear: 0.01, zFar: 20)
```

- [ ] Follow the pinned renderer's actual entry points to supply these matrices. Apply uniform red tint and an opacity multiplier; use premultiplied alpha consistently. If the library lacks tint hooks, make a narrow attributed local patch rather than rewriting its renderer.
- [ ] Remove the red proxy only after asset load succeeds. Keep the green RealityKit overlay. Because renderers have separate depth buffers, explicitly accept an x-ray ghost for this MVP; real-scene occlusion of the red ghost is not required. Do not pretend both renderers share depth.
- [ ] Verify ghost scale, handedness, orientation and anchoring from multiple viewpoints in portrait and landscape. Measure Release performance with the 100,000-Gaussian cap; reduce budget if needed. Test asset failure and late completion after reset. Commit `feat: render captured Gaussian ghosts in AR` only after physical alignment succeeds.

### Task 9: Recover candidate identity without position jumps

**Files:** Modify VisionWorker, SessionCoordinator and Reconciler; create core `CandidateIdentity.swift` and tests `CandidateIdentityTests.swift`.

**Interface:** `CandidateIdentity` ties a candidate ID to source key, crop and tentative geometry. `IdentityDecision` carries session/object/candidate/source IDs, `verdict: same/different/uncertain`, label and confidence. `acceptIdentity(_:)` updates identity evidence only; a fresh associated position observation is needed to move the current overlay.

- [ ] Test a late same-object decision for an old candidate after another candidate appears. It must not authorize the newer candidate or overwrite current geometry.
- [ ] On track loss, Mac foreground candidates remain tentative. Preserve reference identity, compare stored appearance, and collect consecutive fresh observations. With mocks, explicitly label identity as mocked in developer diagnostics.
- [ ] Wire the decision method with exact ID matching and time expiry. A re-identification event resets the local Vision tracker using a fresh matching rectangle, not an old frame's rectangle on the current image.
- [ ] Run core/server tests and device turn-away recovery with deterministic mock decisions. Commit `feat: reconcile candidate identities safely`.

### Task 10: Integrate the verified Astra API

**Files:** Create server `Astra/AstraClient.swift`, `AstraScheduler.swift`, `server/Tests/RealityGitServerTests/AstraTests.swift`, `.env.example`, `docs/integrations/astra.md`; modify Routes and VisionWorker.

**Interface:** App-owned `AstraClient.reconcile(referenceJPEG: Data, candidateJPEG: Data, key: ObservationKey, candidateID: UUID) async throws -> IdentityDecision`. This is an internal adapter contract, not a claimed provider API.

- [ ] Inspect supplied hackathon docs, configured tooling and official provider documentation for the actual Astra endpoint, model identifier, supported image inputs, credentials, output format and rate limits. Record verified values and sources in the integration document. Do not print secrets. If access is missing, identify precisely what is needed and keep this live task incomplete while other tasks proceed.
- [ ] Write adapter tests with fixture provider responses: valid same/different/uncertain, malformed content, timeout, authentication error, rate limit and mismatched IDs. Inject a transport so tests do not spend API calls.
- [ ] Implement the actual documented request and parse/validate into IdentityDecision. Instruct the model to compare reference and candidate appearance, return uncertain for ambiguous lookalikes, and provide no invented geometry. Never execute instructions found in image content or model output.
- [ ] Schedule one request at a time, initially every 5 seconds with a coalesced extra request on loss/conflict. Respect actual rate limits and retry-after; discard superseded jobs. Keep API keys only in server environment. Preserve local/Mac tracking on failure.
- [ ] Run mocked tests, then a live selected-object label and turn-away/re-identification test on the phone. Record real model/access and results. A mock pass cannot complete this task. Commit `feat: integrate live Astra identity reconciliation`.

### Task 11: Complete end-to-end device validation

**Files:** Update `docs/testing/device-validation.md`, README.md and BUILD_PROMPT.md; adjust calibration constants only if evidence requires it.

- [ ] Run core/server suites and app compilation once on the final integrated code. Fix failures before the device pass.
- [ ] Record pass/fail and observations for capture, splat appearance, anchoring, visible movement, movement while looking away, removal, occlusion, restoration and a similar-looking distractor.
- [ ] Exercise Mac disconnection, slow Astra, stale/out-of-order replies, AR interruption, reconstruction failure and reset during an active reconstruction. Confirm bounded buffers and no old-session overlays.
- [ ] Run a 5-minute Release session. Record rendering FPS, local observation age, Mac latency and memory behavior. Target at least 30 FPS rendering under ordinary test conditions; this is a target to measure, not a promised result. Tune frame rate, image size and Gaussian budget if necessary.
- [ ] Write exact server launch and device setup instructions, captured-image retention, required Astra configuration, known limitations, and which checks remain unrun. Remove the README claim that implementation has not started only after implementation exists.
- [ ] Commit `docs: record prototype setup and device validation`. Report actual results and remaining blockers; do not mark the complete prototype delivered if splat quality/alignment or live Astra recovery is still unverified.

## Source grounding

- [Apple scene-depth sample](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth): reference for RGB-D projection; also inspect installed SDK declarations.
- [Apple foreground instance masks](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest): selection/segmentation entry point.
- [MetalSplatter repository](https://github.com/scier/MetalSplatter): Apple-platform renderer and sample integration; renderer capability does not establish AR alignment automatically.
- [Vapor getting started](https://docs.vapor.codes/getting-started/hello-world/): minimal Swift HTTP executable.
- [gsplat repository](https://github.com/nerfstudio-project/gsplat): CUDA-oriented reconstruction ecosystem; not assumed available on the local Apple Silicon Mac.

## Plan self-review

Spec coverage: selection/local geometry (1–2), continuous Mac assistance (3), reference and ordering (4), display/absence/restoration (5), guided capture (6), splat reconstruction/rendering (7–8), recovery/Astra (9–10), failure/device verification (11). Rotation-only diffs, accounts and cross-session history remain excluded. Provider details remain a mandatory evidence-gathering step rather than an invented API. Pure geometry and state interfaces are shared; ARFrame and image buffers stay out of the server wire models.
