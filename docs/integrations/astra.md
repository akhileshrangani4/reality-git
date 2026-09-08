# Astra perception

## Active flow

`Routes.configure` uses `AstraWorker` by default. One full-frame Astra observation replaces the earlier Mac-Vision proposal, label, comparison and retry chain.

1. A tap or drawn box and its exact camera frame go to Astra.
2. Astra returns a short label, identity confidence, normalized top-left bounding box and visible silhouette (or no match).
3. The server keeps the first confident reference crop immutable. Subsequent calls compare that crop against the full current image and locate the same object anywhere in it.
4. The phone samples LiDAR within the model outline. It uses only measured depth and calibration for world geometry. The saved depth surface prepares the native red/green splats once.
5. Between calls, a bounded local Vision sequence advances Astra's pixels. It does not select, identify or independently reacquire objects. An uncertain model response revokes local continuity. Astra-confirmed source depth also directly establishes movement/restoration if no newer spatial evidence contradicts it; a failed Apple advance cannot veto the model snapshot.

The Responses request uses `gpt-6-astra`, `reasoning.effort=low`, `store=false`, image inputs and a strict JSON schema. All output fields are validated, including numeric types, finite/in-bounds coordinates, silhouette area, incomplete responses and refusals. Confidence below 0.8 is treated as unknown. Geometry is measured on the phone; model coordinates are image coordinates only.

## Latency and lifecycle

There is one active request and no five-second comparison gate or 5/10/20/30-second candidate backoff. The provider request timeout is 20 seconds; phone transport allows 25 seconds. The active job pins its source image/depth for up to 30 seconds. Later samples cannot evict it. Fresh local advances provide live geometry. When advancement fails, green can mark Astra’s last measured world position for up to 10 seconds from its source timestamp, with a “last seen” status. Old model image boxes are never directly drawn on a new frame, and old snapshots cannot rewind newer physical observations or confirmed absence.

New selections cancel/retire old results. Duplicate or stale requests cannot replace the immutable reference. Local authority expires after 10 seconds from Astra's confirmed source. Reference geometry survives local tracking loss and interruption until Start over.

## Validation

Automated tests cover tap selection without Apple segmentation, whole-frame reacquisition without a candidate, uncertain initial retries, immutable references, old-selection isolation, bounded provider concurrency, invalid payloads, exact-source retention and sampled depth without shape-signature/background-ring gates.

A live two-call smoke test on a synthetic marked object passed on September 8, 2026: initial selection ~5.3 s and moved-object reacquisition ~3.9 s. This verifies provider/schema integration and image coordinates, not physical tracking accuracy. Run it explicitly with `OPENAI_API_KEY` and `RUN_ASTRA_LIVE=1`, using `swift test --package-path server --filter AstraLiveTests`.

The earlier `VisionWorker`, label-only and candidate-comparison adapters remain as legacy comparison/test fixtures. They are not used by the app's production route.

## Provider grounding

Existing verified contract: [Astra model](https://developers.openai.com/api/docs/models/gpt-6-astra), [image inputs](https://developers.openai.com/api/docs/guides/images-vision), [structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs). The local ignored key is loaded into the server environment and is never put in the phone app or committed.
