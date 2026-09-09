# Reality Git

An iPhone AR prototype that remembers an object's place and shows what changed.

Connect Astra in Settings, tap an object or draw around it, then move it. A red captured-surface ghost marks the remembered place; green follows the object, or marks Astra’s last measured position while local tracking catches up. Returning it clears the diff. Off-camera or occluded objects remain unknown unless measured depth shows the old region is empty.

## Responsibilities

- **GPT-6 Astra, low effort:** Selects the object, labels it, traces its visible silhouette, and finds the same object anywhere in subsequent full camera frames. One structured model call handles each observation. It runs throughout tracking, including after loss.
- **iPhone camera, ARKit and LiDAR:** Supply images, depth, calibration, and world coordinates. Depth inside Astra's outline builds the immutable saved surface. No Apple segmentation, feature-print matching, or shape-signature gate decides identity.
- **Vision:** Advances Astra's pixels between replies for responsive overlays. Buffered images bridge network latency; this local track cannot independently reacquire or identify an object. Astra-confirmed source depth can establish a move or restoration even when this advance fails.
- **RealityKit:** Prepares native Gaussian splats once the reference is captured and shows/hides the cached overlays as movement is confirmed.
- **Local Mac service:** Relays camera images to Astra and holds the reference crop in memory. The API key stays on the Mac.

The main screen contains the camera, one status line, and Settings. Connection, remembered-shape preview and Start over are in Settings. A saved connection is restored on launch; Disconnect forgets it.

During initial capture, a scattered spray of white particles, matching the camera buttons, flows slowly toward the measured selection. Particles carry momentum through smooth turbulence and fade softly as they reach the object. Once the native surface is ready, red points form outward from the contact point and briefly preview the capture. Later red overlays fade in smoothly. These effects follow capture state without adding a processing delay; Reduce Motion disables them.

## Validation

Core and server automated checks, a live Astra selection/reacquisition smoke test on synthetic images, and a signed iPhone build pass. The live smoke measured approximately 5.3 seconds for initial selection and 3.9 seconds for reacquisition; these are individual measurements, not latency guarantees. Sustained physical tracking, lookalikes, occlusion and restoration still require device validation.

The splat is a partial depth surface from the observed view, not a reconstruction of unseen sides. The MVP remains one object, one room, one AR session. Open `ios/RealityGit.xcodeproj` in Xcode 27. See [setup](docs/testing/mac-assistant-setup.md) and [device validation](docs/testing/device-validation.md).
