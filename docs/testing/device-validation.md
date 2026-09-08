# Device validation

## September 8, 2026 — AR foundation

- Xcode 27.0 beta 6 (27A5252f), iOS SDK 27.0.
- Unsigned Debug build for generic physical iOS device: PASS.
- No simulator runtime installed or required for this check.
- Physical iPhone not connected during this build; iOS 27 beta 8 installation reported in progress.
- Camera permission UI, depth availability, world anchor stability, background/resume, interruption/relocalization, and reset: NOT YET TESTED ON DEVICE.

## Run on iPhone

1. Open `ios/RealityGit.xcodeproj` in Xcode 27.
2. Under Signing & Capabilities, choose your development team. Use the RealityGit scheme.
3. Connect and unlock the iPhone, trust this Mac if prompted, and enable Developer Mode if Xcode requests it.
4. Select the actual iPhone as the run destination and run the app.
5. Allow camera access and slowly scan a textured, well-lit area.
6. Confirm an 8 cm mint cube appears about one meter in front of the initial camera position and remains fixed as you walk around it.
7. Background and reopen the app. During poor tracking or interruption, the marker should hide. It should reappear in the original place after relocalization.
8. Tap “Place a new marker.” The old marker must disappear and a new marker should be placed after stable tracking/depth returns.
9. Test camera denial and Settings recovery. Record actual outcomes here, including failures.

A successful compile does not establish real-world geometry or visual correctness. Device signing and all physical checks remain pending.

## Object selection checkpoint

- Tap selection or a drawn box seeds foreground instance segmentation and Vision tracking.
- Masked, confidence-filtered LiDAR samples produce a median visible-surface position in the matching camera frame's world coordinates. This estimate can shift as different surfaces become visible.
- Native camera image coordinates remain unchanged; ARKit's iOS 27 rotation-aware display transform maps touches and overlays.
- Nine core tests pass: camera axes, invalid depth/calibration, depth-to-image mapping, robust median, image rotation, cropping, invalid transforms, and Vision's coordinate origin.
- Unsigned generic-device Debug build: PASS.
- On-device checks pending: tap/box alignment in portrait and landscape, stationary-object position drift, fast motion, ambiguous foreground masks, occlusion, reselection during processing, and background/resume.
- Vision starts with a 5 Hz sampling cap; frame rate, latency, memory and thermal behavior are not yet measured.
- Movement diffs, Mac assistance, Gaussian capture/rendering and Astra integration are still pending.

## First physical-device installation

- Connected iPhone 15 Pro reports iOS 27.0, build 24A5430a; Developer Mode enabled.
- Pairing: PASS. Signed Debug build using the existing development team: PASS. Installation: PASS.
- Initial launch rejected by iOS with developer-trust/security error. Local code-signature verification passed; the provisioning profile includes this device. User developer trust pending.
- No claim yet that camera, depth, world anchor or object tracking works on the device.

## Launch and initial tracking feedback

- After developer trust, launch reached a TCC abort: the packaged Info.plist lacked NSCameraUsageDescription. Xcode had migrated explicit plist keys into generated build settings while the first device build was underway.
- Rebuilt after migration, verified the packaged camera description, installed and launched: PASS. Camera image and DEPTH READY observed on the physical phone.
- User reported tap selection briefly showed a box then became uncertain. Local Vision state was recreated from rectangles each frame. Commit a021fea initializes the sequence on the selected image and retains returned tracking observations.
- a021fea unsigned build, signed device build, packaged camera-description check, installation and launch: PASS. Focused code review found no additional defect in this patch. Sustained tracking and world-anchor stability still need user confirmation.

## Instrumented device run (147e5f0)

- Signed build/install/launch PASS; camera and depth available.
- User reports the floating test cube appears to drift. Recorded world coordinates remained constant across five marker samples while camera translation changed by approximately 15 cm and ARKit reported normal tracking. The cube is placed one meter along the initial view, not on the visible desk; apparent parallax against a closer surface may contribute. This is not proof of physical anchoring accuracy; surface-aligned visual verification remains pending.
- After Vision continuity fix, consecutive successful local observations recorded. Successful source-result ages in this sampled run were generally about 50 ms, with initial selections slower. This is observation age from camera timestamps, not a rendering-FPS measurement.
- Some taps still miss the foreground mask; user should be able to retry or draw a box. Occlusion/recovery, position drift, and sustained long-session behavior remain unverified.

## Task 3 connection smoke

- Launched the Mac service explicitly for LAN use. Real HTTP GET /health returns200 with status ok; malformed POST /observe returns400.
- Shared Wi-Fi blocked reachability: probes to the phone returned “Communication prohibited by filter”; phone Safari could not reach the Mac health endpoint. Switching the Mac to the phone's Personal Hotspot resolved transport: sustained phone POST /observe requests arrived at approximately two per second. This verifies request delivery, not tracking accuracy or recovery.
- User reports tracking stops at about arm's length and does not recover on approach. Local mask-dropout handling is being revised to keep a still-confident temporal 2D track while withholding unreliable metric geometry. No claim that distance/recovery is fixed yet.
- Client fixes e625a6f and debug diagnostics 968d95e built, installed, and pushed. Independent review passed the bounded encoding lifecycle, endpoint reselection, and mask-dropout changes. On the hotspot, the user still reports losing tracking when backing away. True Vision confidence loss remains terminal in this version; Mac evidence is stored but does not yet recover local tracking.
- Recovery followup b1bb8e6 passed independent review and 20 core XCTest tests plus the wire test, including a synthetic real-Vision source-to-current recovery test. Signed build and device installation passed. The new path recovers actual local loss only from fresh, continuous, sufficiently confident Mac tracking evidence; candidates remain unconfirmed. The server was restarted with selection-isolation fix 6a40def. Physical distance/recovery retest remains pending; these changes do not establish anchor stability or recovery accuracy.
- Subsequent user test: distance recovery works. Rapid camera jolts recover intermittently; leaving the frame can still lose identity. User explicitly accepts deferring further tracking tuning to continue the prototype. This is a limited physical pass for distance recovery, not a general robustness pass.

## Movement proxy milestone (bd07fac)

- Immutable reference, ordered masked positions, and red/green world-space boxes implemented. Independent review passed the bounded movement/restoration scope; 26 core XCTest tests plus wire test passed, signed build/install passed. Automatic launch was blocked because the phone was locked; user asked to unlock and open the installed build.
- Move threshold 15 cm; restore within 8 cm; three distinct observations spanning at least 0.5 seconds. Green expires after 0.5 seconds without reliable geometry, red persists after a confirmed move, and AR uncertainty hides both.
- User test: neither overlay appeared. Subsequent screenshot shows Reference saved / current position uncertain and Mac candidate / identity unconfirmed. No move was confirmed in this observation. User asked to retry slow in-frame movement; this remains a failed/incomplete physical movement check, not a rendering pass. Removal detection and Gaussian appearance are not implemented by this increment.
