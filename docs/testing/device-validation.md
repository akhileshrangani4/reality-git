# Device validation

## Current checkpoint — captured Gaussian preview

- Diagnostic build `0ff8235` is now installed and launched. Its tracking behavior is unchanged from `dd16c9e`; it records up to three local, bounded rejection cases with exact signature aggregates and sampled construction inputs. No images or credentials are recorded by this diagnostic. 45 XCTest and 2 Swift Testing checks, native/signed builds, and scoped diagnostic review pass. Device case collection and exact local replay are pending.
- Latest installed phone code: `dd16c9e`. Signed build, installation, and launch pass; 44 XCTest and 2 Swift Testing checks pass. Independent review passes. For an already-associated object, current depth can be measured without an exposed background ring, retaining size/color/support checks. During missing depth, a fresh trusted local image track gets a green screen overlay. Both green paths cover moved and rediscovered objects; stale/uncertain tracks are hidden.
- Physical `dd16c9e` test FAIL: user still sees no green. This run remains in unchanged state because current geometry is rejected before movement confirmation. Logs identify metric-size rejection at local confidence 0.86/0.877, followed by many local tracks below the 0.8 depth-fallback gate. A bounded diagnostic capture is being added to reproduce the actual signature inputs locally; no further threshold change has been made.
- Previous phone code `9ecf7f4`: user again reports only red. Logs show movement confirmed, but current depth repeatedly rejected the correct tight object-face box because its outside ring contained more of the object. This is a failed physical green-overlay test, despite passing tests/builds. It motivated the latest known-shape measurement and current-overlay corrections.
- Phone build `4e30392`: signed build, installation, and launch pass. User confirms the captured shape appears when the remembered-shape preview is enabled. Device logs confirm native Gaussian resources with 846 and 1,536 points.
- The original reference now survives local tracking loss, interruption, and reselection. Current geometry expires separately. Absence requires repeated depth evidence that the old region is visible and empty; loss of tracking alone does not establish absence.
- Server `baaec84`: 26 tests and scoped review pass. Live Astra logs include reference labels and comparison verdicts of `same`, `different`, and `uncertain`; uncertain candidates retry with fresh crops and bounded backoff. This verifies live provider use, not reliable physical reacquisition.
- Phone `4e30392`: 36 XCTest and 2 Swift Testing tests pass. Tight-selection follow-up `52a9d7e`: 38 XCTest and 2 Swift Testing tests, native build, and signed build pass. Installation was deferred during the original movement check; its reviewed corrections are included in `9ecf7f4`.
- User's next physical test, preview off and object moved 20–30 cm: only the red shape appears. The original reference is retained, but the automatic current green overlay is still failing. Restoration and sustained anchor accuracy remain unverified; this is not an end-to-end pass.
- Logs distinguish two remaining gates: Mac `.tracked` replies around 0.54–0.59 do not meet the phone's 0.6 recovery threshold, and healthy local 2D tracks can lack supported depth. Thresholds have not been lowered to turn uncertain evidence into a pass.
- Tight-box review found a slanted support plane could be mistaken for foreground at an image corner. Follow-up `cd4728e` accounts for background slope; independent reproduction rejects three slanted-plane fixtures and retains all 256 points of raised-object counterparts. 39 XCTest and 2 Swift Testing checks plus native build pass; scoped review is clean.

The entries below record earlier checkpoints, including failures that led to these changes.

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

## Selection and semantic handoff correction

- User reports labeling succeeds but tracking continues searching. This is not a successful end-to-end pass.
- Server e416dbc adds a stable continuously tracked candidate ID, bounded Astra reference/candidate comparison, and promotion only after a successful current-frame Vision advance. 23 server tests and independent review pass.
- Phone 4a28e1d starts an explicit drawn selection before segmentation and sends that exact user crop to the Mac. It still requires genuine mask/depth before saving metric reference. Address persistence remains explicit-Connect; OpenAI forwarding is disclosed. 28 core XCTest plus 2 wire tests, independent review, signed build/install/launch pass.
- Updated server restarted with the user's environment key, health passes. Live reacquisition and visible move/restore remain pending; no robustness claim yet.
