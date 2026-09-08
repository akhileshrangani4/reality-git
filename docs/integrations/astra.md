# Astra integration grounding

Verified September 8, 2026 against official OpenAI documentation. Live text access and the image-label integration are implemented; candidate comparison is implemented, reviewed and running on the Mac; live reacquisition accuracy remains pending.

## Verified provider contract

- Model identifier: `gpt-6-astra`. Supports image input and structured outputs. `reasoning.effort` supports `low`, `medium`, `high`, `xhigh`, and `max`. Start with `low` for periodic identity comparisons; measure actual latency. [Model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra).
- Use the Responses API. Image inputs can be `input_image` content with a base64 JPEG data URL; pair reference and candidate with an `input_text` comparison request. Keep metric geometry out of the model decision. [Images and vision](https://developers.openai.com/api/docs/guides/images-vision).
- Request a strict JSON schema through `text.format` with `type: json_schema`. Parse the response's output text, handle refusals and incomplete responses, and validate all application fields. Schema conformance does not establish identity correctness. [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs).

## Implemented application contract

The server labels the selected reference crop asynchronously and returns an optional label to the phone. The user reports receiving a label, but tracking remained lost; labeling alone did not solve reacquisition. Candidate comparison is now implemented separately: immutable reference crop versus a continuously tracked candidate, returning same/different/uncertain plus confidence. Authorization requires the same selection and continuous candidate ID, then a successful current-frame Vision advance; a model answer never supplies geometry.

One provider request runs at a time. Candidate comparisons start no more often than every five seconds. An uncertain, low-confidence, or failed comparison retains a fresh candidate crop and retries with 5/10/20/30-second bounded backoff while continuity remains valid. A different-object verdict retires that candidate and temporarily excludes its region. Local Vision, Mac Vision and rendering continue during failure or delay. Actual account limits and round-trip latency have not been measured.

## Access and validation still required

The user supplied a local ignored environment file. A live Responses request to `gpt-6-astra` completed and returned the requested text on September 8. The running Mac service also returned reference labels and real two-image comparison verdicts including `same`, `different`, and `uncertain`. Credentials were not printed or committed. Server startup loads the key into `OPENAI_API_KEY`; never put it in the iOS app or git. These calls establish live integration, not semantic accuracy or reliable phone reacquisition.

Remaining checks: evaluate lookalikes and occlusions against known outcomes, measure response latency, and validate sustained phone recovery. Physical logs show that a model match can still be followed by low-confidence tracking or missing depth; neither the label nor the match alone produces a current world position. Mocked adapter tests cannot complete this milestone.
