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
- **Gaussian Splats:** A cached first-view surface from LiDAR and camera colors, rendered with iOS 27's native RealityKit splat support. Guided multi-view capture and trained reconstruction remain future work.
- **GPT-6 Astra:** Periodic semantic identity, re-identification, and world-state reconciliation outside the frame loop.

The captured surface is partial and approximate. It preserves the observed shape rather than reconstructing unseen sides; an explicit bounds fallback is shown if native resource creation fails.

## MVP

One object, one room, one AR session. Use confidence thresholds and consecutive observations to suppress false movement and absence reports. Defer cross-session persistence, full-room reconstruction, and history browsing.

See [BUILD_PROMPT.md](BUILD_PROMPT.md) for the implementation sequence. The app runs on the physical iPhone 15 Pro with camera/depth, local and Mac-assisted tracking, live Astra comparisons, an immutable reference, and native captured Gaussian rendering. The user has confirmed seeing the saved shape and the red ghost after moving the object. The green current-position overlay still fails in physical testing; automatic restoration and sustained anchor accuracy are not validated. See [device setup and validation](docs/testing/device-validation.md) for the current checkpoint and earlier failures. Open `ios/RealityGit.xcodeproj` with Xcode 27.
