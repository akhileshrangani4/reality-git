# Codex companion setup

Install Codex CLI and sign in with ChatGPT. The integration was verified with Codex 0.153.4. It uses the documented app-server protocol; it does not reuse subscription credentials for ordinary API requests.

## Run

From the repository root:

```sh
codex login
swift run --package-path server RealityGitServer --lan --pair-address http://YOUR-MAC.local:8080
open ~/.reality-git/connect.html
```

Replace YOUR-MAC with the Mac's local hostname, or use its private IPv4 address. The companion writes a private pairing card and connection link to `~/.reality-git/`. The token persists across restarts. `CODEX_BINARY` can select a Codex executable if it is not on PATH. `REALITY_GIT_STATE_DIR` can select a separate companion state directory.

Without `--lan`, the service binds to localhost. The LAN prototype uses HTTP on port 8080 and must stay on a trusted private network. Pairing authorizes account controls and scan requests; it does not encrypt local traffic. Do not expose it to the public internet. OAuth credentials remain managed by Codex on the Mac.

## Connect the iPhone

1. Scan the pairing card using the iPhone Camera. The link opens Reality Git Settings. Tap **Connect**. Alternatively, paste the connection link into Settings.
2. If Codex is already signed in with ChatGPT, the account and model list appear automatically.
3. Otherwise, tap **Sign in with ChatGPT**, copy the displayed device code, and continue to the official ChatGPT page. Return to the app when finished. If device-code sign-in is unavailable, sign in with `codex login` on the Mac and tap **Reconnect**.
4. Choose an available image model under **Model**. Astra is the default when available. Every offered model supports images and low effort.
5. Tap **Done**, then tap an object to scan. Allow local network and camera access when prompted.

The phone stores only its companion pairing link in Keychain. Model preference is saved separately. **Disconnect this iPhone** forgets pairing without signing the Mac out of ChatGPT.

Keep the companion running. After a companion restart or network change, reconnect and start a new scan. Regenerate the pairing card with the new address if needed. To revoke a lost phone, stop the companion, remove its pairing-token file and old pairing card/link, then restart and pair your phone again.

## Checks

```sh
curl http://127.0.0.1:8080/health
swift test --package-path Packages/RealityGitCore
swift test --package-path server
```

Health only verifies the HTTP service. Account and observation routes require the pairing bearer token. Never put a ChatGPT token or OpenAI API key in the phone app.

The default frame long edge is 960 pixels. The phone has one active request, a 25-second transport deadline, and preserves the exact image/depth source for up to 30 seconds. Old image boxes are never drawn directly on a new frame.
