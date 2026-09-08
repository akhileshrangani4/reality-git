# Astra integration grounding

Verified September 8, 2026 against official OpenAI documentation. Live text access is verified; image-label integration is in progress.

## Verified provider contract

- Model identifier: `gpt-6-astra`. Supports image input and structured outputs. `reasoning.effort` supports `low`, `medium`, `high`, `xhigh`, and `max`. Start with `low` for periodic identity comparisons; measure actual latency. [Model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra).
- Use the Responses API. Image inputs can be `input_image` content with a base64 JPEG data URL; pair reference and candidate with an `input_text` comparison request. Keep metric geometry out of the model decision. [Images and vision](https://developers.openai.com/api/docs/guides/images-vision).
- Request a strict JSON schema through `text.format` with `type: json_schema`. Parse the response's output text, handle refusals and incomplete responses, and validate all application fields. Schema conformance does not establish identity correctness. [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs).

## Application contract to implement

A server-only adapter compares the saved reference crop with a tentative candidate crop. It returns same/different/uncertain, semantic label and confidence. The server attaches the exact session/object/candidate/source IDs from the request context. Stale decisions cannot authorize newer candidates or move a current overlay.

One request at a time; initially no more often than every five seconds, with a coalesced uncertainty trigger. Respect account-specific limits and retry-after responses. Local Vision, Mac Vision and rendering must continue during failure or delay. Actual account limits and round-trip latency have not been measured.

## Access and validation still required

The user supplied a local ignored environment file. A live Responses request to `gpt-6-astra` completed and returned the requested text on September 8. Credentials were not printed or committed. Production server startup must load the key into `OPENAI_API_KEY`; never put it in the iOS app or git. Image comparison and semantic accuracy remain unverified.

Remaining checks: authenticate, run one real two-image comparison, verify ambiguous lookalikes return uncertainty, measure response latency, and exercise actual phone recovery. Mocked adapter tests cannot complete this milestone.
