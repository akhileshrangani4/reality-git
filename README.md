# Reality Git

An iPhone AR prototype that remembers an object's place and shows what changed.

Sign in with ChatGPT on the iPhone, choose an image model, then tap an object or draw around it. A red captured surface marks its remembered place; green shows its latest measured position. Returning the object clears the difference.

## Intelligence and hardware

- **Codex subscription models:** Select, label, outline, and find the same object in subsequent camera frames. GPT-6 Astra is the default when available. Settings loads each account's image-capable models that support low effort; all scans use low effort.
- **iPhone camera, ARKit, and LiDAR:** Supply images, depth, calibration, and world coordinates. Measured depth inside the model's outline creates the immutable saved surface.
- **Vision:** Advances the model's pixels between replies. It cannot independently identify or reacquire the object. Model-confirmed depth can establish movement even if this local advance fails.
- **RealityKit:** Renders native Gaussian splats. Slow white particles match the camera controls, scatter toward the selected surface, and fade at contact. Reduce Motion disables the capture animation.
- **Fast capture:** A tap immediately previews a bounded patch of measured depth while Astra confirms the object. The preview is never saved as a reference or used to establish movement. Cached pixel continuity carries Astra's outline forward, with tracking scheduled up to 30 times per second. GPU resources, resized tracking images, reference crops and repeated JPEG encodes are reused.
- **Native Swift connection:** The iPhone signs in, stores credentials in Keychain, renews tokens and sends images directly to OpenAI using the Codex subscription protocol. No API key, Mac companion or local server is used by the app.

The camera has one status indicator and Settings. Settings uses native SwiftUI forms, navigation, system colors, SF Symbols, Dynamic Type, and Liquid Glass controls. Choose a model under **Settings → Model**. Changing models starts a new scan.

## Run and connect

Open **Settings → Sign in with ChatGPT**, copy the one-time code and complete sign-in on OpenAI's page. Return to the app, choose your model and tap **Done**. Each user uses their own Codex allowance. See [native iPhone setup and implementation](docs/native-codex.md). Internet access is required; the model runs in OpenAI's cloud.

Open `ios/RealityGit.xcodeproj` in Xcode 27. The native splat renderer requires iOS 27 and a supported LiDAR iPhone.

## Validation

The iPhone performance fixture submits the first depth preview in 26 ms and processes the first Astra result in 30 ms (previously 121 ms). At the new 30 Hz sample cadence, tracking costs 14 ms at the 95th percentile and all 119 samples succeed. These are device CPU/submission measurements with a simulated model delay, not camera FPS or end-to-end inference latency. Initial semantic confirmation still requires a cloud response. See the [performance report](docs/testing/capture-speed-device-results.json).

Native authentication, refresh, cancellation, model filtering, request formatting and response-stream checks pass alongside the core camera tests. Debug and Release iPhone builds pass. Phone sign-in, model discovery and direct subscription inference were verified with the Mac companion stopped. Astra located the complete synthetic object before and after movement in about 6.1 and 5.6 seconds. These are integration samples, not a latency or real-world tracking guarantee.

The same native test reached Luna successfully, but one moved-object result selected only its internal marking. The diagnostic now checks overlap with the whole target rather than displacement alone. Astra remains the default; model availability does not guarantee equal perception quality. See the [device validation log](docs/testing/device-validation.md) for details.

Earlier companion tests with Astra and Luna located a synthetic marked object and reacquired it after movement in approximately 5.9–7.7 seconds. Those measurements belong to the previous Mac architecture, not the native connection.

Physical iPhone screenshots check connection, account, and model screens, including dark mode and larger text. The splat remains a partial surface from measured depth, not a reconstruction of hidden sides. Scope is one object, one room, one AR session.

See [native Codex integration](docs/native-codex.md), [perception](docs/integrations/astra.md), and [device validation](docs/testing/device-validation.md). The legacy server and its [protocol notes](docs/integrations/codex.md) remain for regression testing; the iPhone no longer connects to them.
