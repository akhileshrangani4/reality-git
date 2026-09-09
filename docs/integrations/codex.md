# Codex subscription integration

Historical Mac implementation. The current iPhone uses the [native Swift connection](../native-codex.md) and no longer pairs with this server. The server remains for legacy regression tests.

The phone talks to a paired personal Mac companion. The companion embeds a private `codex app-server --stdio` process and uses its owner's ChatGPT subscription access. This is not a phone-native Codex runtime or a public multi-user service.

## Protocol

- `initialize` / `initialized` establish the private connection.
- `account/read` checks for a ChatGPT account; API-key accounts are not used for scans.
- `account/login/start` with `chatgptDeviceCode` supports sign-in from the phone. Codex owns OAuth token storage and refresh. Pending sign-in can be cancelled; the phone never receives OAuth tokens.
- Paginated `model/list` builds the catalog. Hidden models, text-only models, and models without low effort are excluded. Empty or missing capabilities fail closed.
- Each observation starts an ephemeral thread and supplies text, image data URLs, low effort, and the strict object-location output schema. The first reference is held by the worker, not conversation history. Completed threads are unsubscribed.
- JSON-RPC replies and turn events are correlated; early completion notifications are buffered. Pending calls and turns have deadlines. A timed-out turn closes its process before releasing the worker's physical slot.

The runtime disables shell execution, apps, plugins, browser, image generation, image file viewing, and web search. Because empty configuration tables merge with user settings, it explicitly disables every inherited MCP server. Effective configuration is verified before use. Current CLI overrides require MCP names using letters, numbers, underscores, or hyphens; other names fail closed. Threads run in an empty companion directory with read-only permissions and no command network access. Interactive tool requests are rejected.

The companion requires a random 256-bit pairing token for `/account`, `/login`, `/login/cancel`, and `/observe`. Only `/health` is public. Phone requests reject redirects and bound response size. The pairing token is stored in Keychain on the phone and in an owner-only file on the Mac. Pairing cards are private local files, never HTTP endpoints. Local HTTP requires trusted Wi-Fi; a public deployment would need TLS and per-user isolated runtimes, authentication, and lifecycle management.

## Verification

Core tests check capability filtering, pairing links, geometry, and observation lifecycle. Server tests check unauthorized routes, pairing-token persistence/permissions, early protocol notifications, and deadlines. Legacy API regression tests still run, but the API is not the production path.

For the opt-in live test, first start an isolated companion:

```sh
REALITY_GIT_STATE_DIR=/tmp/reality-codex-integration swift run --package-path server RealityGitServer --pair-address http://127.0.0.1:8081 serve --port 8081
```

Then in another terminal:

```sh
REALITY_CODEX_LIVE=1 swift test --package-path server --filter CodexTests
```

The live test uses the signed-in subscription and makes four image calls: selection and movement with Astra and Luna. `REALITY_CODEX_MODELS` can override the comma-separated model IDs. It validates model choice, low-effort turns, typed output, exact source keys, and measured image displacement. The full interactive OAuth ceremony still requires a person to authenticate; live validation reused an already signed-in account.

## Native interface

The camera keeps its white controls and a single status indicator. Connection and account controls live in a system sheet with a SwiftUI Form. Model selection uses a pushed list with a native checkmark. SF Symbols, system typography, semantic colors, and Liquid Glass navigation follow Apple's conventions. Settings supports system light/dark appearance and Dynamic Type; capture effects respect Reduce Motion. Debug `--settings-preview` renders the real settings views on the phone for screenshots, with optional `--models-preview`, `--connect-preview`, `--dark-preview`, or `--large-text-preview`.

Sources: [Codex app-server](https://developers.openai.com/codex/app-server/), [Codex authentication](https://developers.openai.com/codex/auth/), [Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Apple sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Apple accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
