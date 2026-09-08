# Reality Git prototype design

Date: 2026-09-08

## Scope

Build an iPhone 15 Pro prototype that remembers one selected object's appearance and reference position, detects changes, and displays an AR diff. Support one object, one room, and one uninterrupted AR session. A nearby Mac/server assists continuously and reconstructs Gaussian Splats. GPT-6 Astra provides semantic identity and re-identification through its available API.

Use Swift, ARKit, RealityKit, and Vision on the phone. Add Metal only if the chosen splat renderer requires it. Prefer a small server with direct request/response interfaces over generalized infrastructure.

Exclude accounts, full-room reconstruction, history browsing, cross-session persistence, multiple simultaneous objects, and rotation-only diffs. No manual commit step is required.

## User flow

1. Start an AR session and establish stable world tracking.
2. Select an object by tapping or drawing a box. Allow adjustment of the selection before capture.
3. Guide the user to move the phone around the object. Capture masked images, depth, camera intrinsics, and camera poses. The object should remain stationary during capture; reject or retry an inadequate capture.
4. Save its initial reference position and approximate bounds. Begin tracking with a geometric proxy while the Mac reconstructs the splat.
5. Replace the proxy with the returned splat when available. Reconstruction failure leaves the proxy usable and allows another capture attempt.
6. Show the change relative to the captured reference. Observations never automatically replace that reference.

## Responsibilities

### iPhone

Own the session, reference, latest accepted object state, and displayed overlays. ARKit supplies camera poses and world tracking; LiDAR supplies depth for approximate geometry. Local vision follows the selected object between server observations. RealityKit renders anchors and proxies; the splat renderer consumes the same reference transform.

Retain a bounded buffer of sampled frames and their depth, intrinsics, orientation, and camera transforms until a response arrives or expires. Convert returned detections to world coordinates using their source observation, never the latest camera pose. Rendering and local tracking continue without waiting for networking.

### Mac/server

Receive a modest continuous stream of sampled observations and run object localization assistance. Return masks or detections, confidence, session ID, object ID, and source frame ID. Use bounded work queues and drop superseded frames rather than accumulating latency. Sampling rate and image size are configurable and tuned on the actual device.

Reconstruct a cached object splat from the guided capture as a separate job. Return its asset and explicit object-local coordinate transform, units, and bounds so the phone can align it with the reference anchor. Keep the capture and asset scoped to the current prototype session.

Forward selected observations to Astra, with credentials stored on the server. Use periodic identity reconciliation and extra requests when trackers lose confidence or disagree. Continuous server vision does not imply an Astra request for every sampled frame.

### Astra

Assign a semantic label to the selected object, assess candidate matches against its reference appearance, and reconcile conflicting identity evidence. Astra is not the frame-rate tracker or the authority for metric geometry. Its results carry the relevant observation identifiers and confidence; uncertain identity cannot confirm a relocation.

Inspect the actual available Astra API before implementation. Do not assume undocumented endpoints or response formats. A mock integration may support development, but live semantic re-identification is required to validate the final integration milestone.

## Data and reconciliation

Maintain an object ID, semantic label, reference transform and bounds, current accepted position, appearance asset reference, identity confidence, visibility evidence, observation timestamp, and change state. Keep change state separate from tracking confidence: a confirmed move may remain known while the object's current location is temporarily unknown.

Each observation includes session ID, frame ID, capture time, camera intrinsics and transform, image orientation, and the depth required for localization. Each result identifies its source observation. Reject results from another session or object, expired source buffers, and invalid geometry.

Local tracking supplies fast position estimates. Server detections provide continuing corrections and recovery candidates. Require several consistent observations plus sufficient identity confidence before confirming a move or restoration. Older results may contribute identity evidence but cannot overwrite a newer accepted position.

Use configurable movement and restoration tolerances with hysteresis and confirmation windows to suppress jitter. Set concrete values during physical-device calibration; these are tuning parameters, not different product behaviors. Restoration compares approximate position only; orientation remains available for rendering captured appearance but does not trigger a diff.

## Display rules

| Evidence | Display |
| --- | --- |
| Object remains near reference | No diff overlay |
| Confirmed move, current position confidently tracked | Translucent red ghost at reference; translucent green overlay at current object |
| Confirmed move, current position temporarily unknown | Retain red at reference; hide green; indicate tracking uncertainty |
| Reference region visible and object repeatedly confirmed absent | Red ghost only |
| Off-camera or occluded before any confirmed change | Do not infer absence or create a new diff |
| Object consistently restored near reference | Clear both overlays |

The red ghost always represents the initial reference, not the immediately preceding observation. The green overlay can use a local mask or approximate geometry; it does not require continuous splat reconstruction.

Absence requires adequate visibility of the reference region, usable tracking/depth, and repeated negative observations. Evidence of an occluder makes absence unknown. Never infer absence merely because a detector failed once.

## Failure handling

- **Server unavailable:** Continue local tracking and proxy or cached-splat rendering. Indicate uncertainty if identity cannot be maintained. Resume with current observations on reconnect.
- **Astra slow or unavailable:** Continue geometry and local/server tracking. Leave ambiguous identity unresolved rather than switching to a similar-looking object.
- **AR tracking unreliable:** Hide world overlays temporarily and guide the user to rescan. Resume only when the original coordinate frame is recovered; otherwise restart selection and capture in a new session.
- **Splat reconstruction fails:** Keep the geometric proxy and offer recapture. Do not claim a proxy is a completed splat integration.
- **Stale responses:** Discard stale position updates and all responses from invalidated sessions. Cancel or ignore outstanding capture jobs after reset.

## Build sequence

1. Establish stable AR world tracking and a fixed test anchor.
2. Select and locally track one object; introduce continuous Mac localization assistance.
3. Store the reference pose separately from current observations.
4. Detect relocation with confidence checks and ordered reconciliation.
5. Render red reference and green current proxies; implement absence, uncertainty, and restoration behavior.
6. Add guided multi-view capture, server Gaussian-splat reconstruction, and aligned iPhone splat rendering. Retain the proxy fallback.
7. Integrate live Astra labeling and semantic re-identification with periodic and uncertainty-triggered checks.

Keep each stage demonstrable before adding the next. Validate splat alignment explicitly against the selected object before relying on it for ghosts.

## Validation

On the physical iPhone, verify stable anchoring while walking around, guided capture, movement while visible, movement while looking away, removal, occlusion, and restoration. Confirm that a similar-looking object is not silently accepted as the target. Exercise delayed and out-of-order responses, server disconnection, reconstruction failure, and AR tracking loss.

Automated tests focus on consequential logic: reference preservation, movement/restoration confirmation, absence versus occlusion, stale result rejection, and session reset invalidation. Simulator or mocked checks do not substitute for camera, LiDAR, anchor stability, splat alignment, and responsiveness checks on the phone.

The complete prototype succeeds when the selected object can be captured as a splat, moved or removed with the correct anchored diff, recovered with live Astra identity assistance, and restored to clear the diff, while local rendering remains responsive during server work.
