# Starter build prompt

Build an iOS hackathon prototype called Reality Git targeting iPhone 15 Pro. Use Swift, ARKit, RealityKit, and Vision, with LiDAR depth for approximate geometry and world-space positioning. Add Metal only if Gaussian-splat rendering requires it. Optimize for a working MVP with minimal dependencies and abstractions.

Implement and verify these milestones in order:

1. Stable AR world tracking with a visible test anchor that stays fixed as the phone moves.
2. Selection and local tracking of one object. Start with tap or rectangle selection; estimate world-space position using depth.
3. Store the reference pose and approximate bounds separately from the current observed pose.
4. Detect relocation using configurable thresholds and several consistent observations. Treat occlusion, poor tracking, and off-camera objects as unknown. Confirm absence only when the previous region is visible with sufficient evidence.
5. Render a translucent red proxy at the reference pose and a translucent green overlay at the current pose when moved. Show only red when confidently absent. Clear the diff when restored within a reasonable pose tolerance.
6. Integrate short masked multi-view capture and cached Gaussian-splat appearance. Replace the red proxy with the captured splat; retain a proxy fallback.
7. Integrate GPT-6 Astra for periodic semantic identity, re-identification, and world-state reconciliation using selected frames and observations. Keep network calls outside the frame loop; local tracking and rendering must continue while Astra is pending or unavailable.

Keep the initial captured pose as the session reference. Maintain only the state needed: object ID, semantic label, reference pose, current pose, appearance reference, confidence, visibility, and last observation time.

Begin by inspecting the workspace and implementing milestone 1. Verify each milestone before adding the next. Distinguish simulator checks from physical-device validation. Inspect available Astra interfaces before integrating them; do not invent APIs. If credentials are missing, provide a small mock implementation and identify the required configuration. Do not commit credentials.

Avoid accounts, cloud infrastructure, cross-session persistence, full-room reconstruction, history browsers, and generalized frameworks.
