# Native iPhone Codex connection

Reality Git connects from the iPhone directly to OpenAI over HTTPS. The shipping iOS target has no companion URL, local-network entitlement, pairing screen, subprocess, or API-key input. The model itself still runs in OpenAI's cloud; the phone owns authentication, image transport, reference memory, camera/depth processing and rendering.

## Sign in on the phone

1. Open Reality Git → Settings → **Sign in with ChatGPT**.
2. Copy the one-time code, tap **Continue to ChatGPT**, and authenticate on `auth.openai.com`. Device authorization may need enabling in your ChatGPT security settings.
3. Return to Reality Git. It completes the exchange directly and loads your account's models.
4. Choose **Model** if desired, tap **Done**, then tap the object to scan.

No API key or running Mac is used. Each user authenticates their own account and uses their own Codex allowance. Internet access is required. Xcode on a Mac is used to build/install this development app, not to run scans.

## Native implementation

- `NativeCodexClient` ports the connection protocol from OpenAI's Apache-2.0 Codex implementation. This is a Swift client, not an official OpenAI iOS SDK or the entire desktop coding-agent runtime.
- Device authorization uses `/api/accounts/deviceauth/usercode` and `/deviceauth/token` on `auth.openai.com`, then exchanges the authorization code at `/oauth/token` with its PKCE verifier. Pending authorization honors the server polling interval and expires after 15 minutes.
- Access and refresh tokens are stored only in a dedicated iPhone Keychain item with `WhenUnlockedThisDeviceOnly`. They are never imported from the Mac, logged, written to application documents, synced or backed up. Sign-out removes this local item. Existing desktop sign-in is independent.
- Expired access tokens are refreshed through a single shared operation. Rotated credentials are persisted even when a scan is cancelled. Sign-out and cancelled authorization invalidate late completions; permanent refresh rejection requires a new login. Transient failures do not erase a usable sign-in.
- Model discovery uses the Codex backend's `/models` catalog. Only visible models explicitly declaring image input and low effort appear. Astra is preferred when present; selection follows actual account availability.
- Image requests go directly to the Codex `/responses` endpoint with the user's bearer and account routing header. Requests identify this client as `RealityGit/1.0` / `reality_git_ios`; no official-client impersonation or access-denial fallback is used.
- Every request uses low effort, `store: false`, no tools, streaming, and the existing strict object-location schema. The transport rejects redirects and bounds response bytes, line size, and total request time. Only a complete valid response becomes evidence; partial, failed, refused or oversized output is rejected.
- `NativeScanSession` keeps the immutable first model-confirmed reference in memory. It permits one physical inference at a time and checks selection generation and source keys before publishing a reply. Reset and model changes still invalidate old camera evidence.

These endpoints follow the open-source Codex client protocol and may change independently of the public API. An account/server rejection is surfaced in Settings, not worked around. Device sign-in and live image compatibility must be verified on the target account.

## Verification

Run `swift test --package-path Packages/RealityGitCore` for deterministic auth, refresh, cancellation, catalog, request and stream checks alongside the camera geometry tests. Build `ios/RealityGit.xcodeproj` with Xcode 27 for a LiDAR iPhone on iOS 27.

The Debug-only `--native-codex-check` launch argument uses the phone's existing Keychain sign-in to send synthetic selection and movement images directly with Astra and Luna when available. It writes a bounded result report to `Documents/native-codex-check.json`, containing model IDs, timings and rectangles only. It does not import or export credentials. Stop the legacy companion before this check to verify independence. Restart the app normally afterward.

`--settings-preview` renders the actual native settings for light/dark and Dynamic Type checks. A build or mocked transport pass is not a live subscription or real-world tracking pass. See [device validation](testing/device-validation.md) for the current evidence.

## Source and attribution

Protocol reference: OpenAI Codex revision [`a3ba42b`](https://github.com/openai/codex/tree/a3ba42b0108db0bbff97e97f97b3fae8ea3e973e), specifically `codex-rs/login/src/device_code_auth.rs`, `login/src/server.rs`, `login/src/auth/manager.rs`, and `codex-api/src/endpoint/{models,responses}.rs`. The application bundles [ThirdPartyNotices.txt](../ios/RealityGit/ThirdPartyNotices.txt), including the Apache-2.0 license.

Official documentation: [Codex authentication](https://developers.openai.com/codex/auth/) and [custom app-server clients](https://developers.openai.com/codex/app-server/).
