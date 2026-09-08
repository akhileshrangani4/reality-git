# Reality Git

An iPhone AR prototype that tracks changes to objects in a room and displays their previous positions.

The user scans a room and selects objects to track. The system automatically records semantic identity, approximate 3D appearance, and world-space pose without a manual commit step.

## Behavior

- **Unchanged:** No overlay.
- **Moved:** A translucent red Gaussian-splat ghost at the reference pose and a translucent green overlay at the current pose.
- **Absent:** Only the red ghost, after the previous region is visible and absence is confidently established. Off-camera or occluded objects remain unknown.
- **Restored:** Returning to approximately the reference pose clears the diff.

For the MVP, the initial captured pose remains the reference; observations update the current pose separately.

## Approach

- **iPhone 15 Pro, ARKit, and LiDAR:** Camera tracking, depth, anchors, and world coordinates.
- **Vision and local tracking:** Fast object observations that keep the experience responsive.
- **RealityKit:** AR overlays and scene management.
- **Gaussian Splats:** Cached approximate object appearance from a short masked multi-view capture. Use Metal only if needed for rendering.
- **GPT-6 Astra:** Periodic semantic identity, re-identification, and world-state reconciliation outside the frame loop.

Splat capture quality and reconstruction speed are prototype risks. Start with a translucent geometric proxy and replace it after the basic interaction works.

## MVP

One object, one room, one AR session. Use confidence thresholds and consecutive observations to suppress false movement and absence reports. Defer cross-session persistence, full-room reconstruction, and history browsing.

See [BUILD_PROMPT.md](BUILD_PROMPT.md) for the implementation sequence. The iOS AR foundation, tap/box selection, local Vision tracking, and masked LiDAR position estimates are implemented and compile with Xcode 27. Nine core geometry tests pass. Physical-device validation is pending. Open `ios/RealityGit.xcodeproj`; see [device setup and validation](docs/testing/device-validation.md).
