# Reality Git

An iPhone AR prototype that remembers an object's place and shows what changed.

Connect your Codex account, choose an image model, then tap an object or draw around it. A red captured surface marks its remembered place; green shows its latest measured position. Returning the object clears the difference.

## Intelligence and hardware

- **Codex subscription models:** Select, label, outline, and find the same object in subsequent camera frames. GPT-6 Astra is the default when available. Settings loads each account's image-capable models that support low effort; all scans use low effort.
- **iPhone camera, ARKit, and LiDAR:** Supply images, depth, calibration, and world coordinates. Measured depth inside the model's outline creates the immutable saved surface.
- **Vision:** Advances the model's pixels between replies. It cannot independently identify or reacquire the object. Model-confirmed depth can establish movement even if this local advance fails.
- **RealityKit:** Renders native Gaussian splats. Slow white particles match the camera controls, scatter toward the selected surface, and fade at contact. Reduce Motion disables the capture animation.
- **Mac companion:** Runs a private Codex app-server process using its owner's ChatGPT sign-in. Holds the reference in memory and accepts scans only from a paired phone. No OpenAI API key is needed.

The camera has one status indicator and Settings. Settings uses native SwiftUI forms, navigation, system colors, SF Symbols, Dynamic Type, and Liquid Glass controls. Choose a model under **Settings → Model**. Changing models starts a new scan.

## Run and connect

Follow [companion setup](docs/testing/mac-assistant-setup.md). The companion must remain running on the same trusted network as the phone. This is a personal Mac companion prototype, not a shared public subscription gateway. Each user needs their own signed-in runtime.

Open `ios/RealityGit.xcodeproj` in Xcode 27. The native splat renderer requires iOS 27 and a supported LiDAR iPhone.

## Validation

Core and server automated checks pass. Live subscription tests with Astra and Luna located a synthetic marked object and reacquired it after movement. On September 9, 2026, four calls measured approximately 5.9–7.7 seconds. These samples verify the integration, not real-world tracking quality or a latency guarantee.

Physical iPhone screenshots check connection, account, and model screens, including dark mode and larger text. The splat remains a partial surface from measured depth, not a reconstruction of hidden sides. Scope is one object, one room, one AR session.

See [Codex integration](docs/integrations/codex.md), [perception](docs/integrations/astra.md), and [device validation](docs/testing/device-validation.md).
