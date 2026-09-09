# Model perception

The production companion uses `configureCompanion`, `CodexRuntime`, and `AstraWorker`. Astra is the default, with other compatible subscription models available through Settings.

1. A tap or drawn box and its exact camera frame go to the selected model through Codex.
2. The model returns a label, confidence, normalized top-left rectangle, and visible outline, or no match.
3. The companion keeps the first confident reference immutable. Later observations compare its crop against the full current image.
4. The phone samples LiDAR inside the returned outline. Only measured depth and camera calibration establish world geometry.
5. A bounded Vision sequence advances the model's pixels between calls; it cannot independently select, identify, or reacquire an object. Uncertain model output revokes local continuity.

`AstraPerception` provides the shared prompt, schema, crop, and output validation. Codex turns supply image inputs, `effort: low`, and `outputSchema`. The model ID comes from the account's capability-filtered catalog. Numeric types, finite coordinates, outline area, completed status, and output count are validated. Confidence below 0.8 remains unknown.

## Lifecycle

One physical observation runs at a time. New selections retire older generations; cancellation cannot release the slot until the provider returns. The reference is never replaced by a later frame. Each phone job retains its exact RGB/depth source, so latency cannot mismatch a result with a newer camera image. Local authority expires ten seconds after the last confirmed source.

Transport failures back off rather than continuously submitting. Invalid pairing, signed-out accounts, and unsupported models pause scanning with a Settings action. Rate or usage limits receive a longer retry interval. Switching models resets the scan.

Core and server tests cover selection, full-frame reacquisition, immutable references, old-selection isolation, bounded concurrency, payload validation, depth geometry, and protocol deadlines. Live Codex subscription checks passed for Astra and Luna on synthetic images. They do not establish physical tracking accuracy.

The earlier API, Vision-only, label, and comparison adapters remain as regression fixtures. The normal executable starts the paired Codex companion and requires no API key. See [Codex integration](codex.md).
