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
