# CodingAgentKit

A cross-platform Swift package for driving coding-agent servers over HTTP + SSE. It speaks two backends behind one unified model:

- **opencode** (`opencode serve`) — multi-provider, file browsing, diffs, permissions.
- **Claude Code** via [`agentapi`](https://github.com/coder/agentapi) — a subscription-billed Claude Code session exposed over HTTP.

It compiles, tests, and **runs on Linux and Apple platforms**. No `URLSession.bytes`, no Keychain, no OSLog in the core — so it works headless on a server as well as inside an iOS app.

## Why

Both opencode and Claude Code expose an HTTP surface with a Server-Sent Events stream. Their wire formats differ (opencode streams fine-grained part deltas; agentapi re-sends whole messages), but a client wants one transcript model to render. CodingAgentKit hides that difference behind a `CodingAgentBackend` protocol and a `MessageReducer` that folds either event style into one ordered `[ChatMessage]` — which is the reusable heart you can drop into a UIKit app, a CLI, or a TUI.

## Modules

| Product | Purpose |
|---|---|
| `AgentCore` | Transport (URLSession REST + SSE), unified models, `CodingAgentBackend`, `MessageReducer`, `AgentConversation`, protocols (`SecretStore`, `SessionCache`), swift-log facade. No backend specifics, no Apple-only imports. |
| `OpenCodeKit` | Hand-written opencode client + event decoder + `OpenCodeBackend` (conforms `FileBrowsingBackend`). |
| `ClaudeCodeKit` | Hand-written agentapi client + event decoder + `ClaudeCodeBackend`, with an SSE stream and a polling fallback. |
| `CodingAgentKit` | Umbrella that re-exports the three. |
| `AgentTestSupport` | `MockBackend` (scriptable, injectable mid-stream failure) + SSE replay helpers for previews and deterministic tests — no live server needed. |
| `CodingAgentKitApple` | Apple-only companion: `KeychainSecretStore`, `ConnectionProfile`, `ConnectionProfileStore`. Empty on Linux so the core stays portable. |
| `codeagent` | Scriptable CLI that exercises the whole stack. |

`OpenCodeKit` and `ClaudeCodeKit` depend only on `AgentCore`; the core never imports a concrete backend.

## Requirements

- Swift 6.1+ (developed and CI'd on 6.2).
- Linux or Apple (iOS 18+ / macOS 15+).

## Install

```swift
.package(url: "https://github.com/guitaripod/CodingAgentKit.git", from: "0.1.0")
```

Then depend on the umbrella, or just the pieces you need:

```swift
.product(name: "CodingAgentKit", package: "CodingAgentKit")
// or: "AgentCore", "OpenCodeKit", "ClaudeCodeKit"
```

## Library usage

```swift
import CodingAgentKit

let backend = OpenCodeBackend(config: ServerConfig(
    baseURL: URL(string: "http://100.x.y.z:4096")!,
    credentials: BasicCredentials(password: "…")
))

let session = try await backend.createSession(title: nil)
let conversation = AgentConversation(backend: backend, sessionID: session.id)

Task {
    try await conversation.send("List the Swift files in this project.")
}

// One AsyncStream of full snapshots — ideal for a UIKit view controller.
// Auto-reconnects with backoff; surfaces status, permission prompts, failures, and connection phase.
for await state in await conversation.states() {
    render(state.messages)              // [ChatMessage], updated as events arrive
    spinner.isHidden = state.status != .running
    banner.isHidden  = state.connection == .live
    if let permission = state.pendingPermissions.first {
        try await conversation.respond(to: permission, decision: .once)
    }
}
```

Swap `OpenCodeBackend` for `ClaudeCodeBackend` and the rest is identical — that is the point of the unified model. For tests and previews, use `MockBackend` from `AgentTestSupport` instead of a live backend.

## CLI

```
codeagent health   [--backend opencode|claude] [--host URL] [--password …]
codeagent discover                   # probe URL, auto-detect backend
codeagent sessions
codeagent new
codeagent send <session-id> "<prompt>" [--model providerID/modelID] [--attach FILE]
codeagent stream <session-id>
codeagent diff <session-id>          # opencode
codeagent files [path]               # opencode
codeagent find <pattern>             # opencode
codeagent providers                  # opencode
```

Config resolves from flags, then environment: `OPENCODE_HOST`, `OPENCODE_SERVER_PASSWORD`, `OPENCODE_SERVER_USERNAME`, `AGENTAPI_HOST`.

```bash
export OPENCODE_SERVER_PASSWORD=secret
codeagent send "$(codeagent new)" "Summarize README.md"
```

## Running the backends

### opencode

```bash
OPENCODE_SERVER_PASSWORD=secret opencode serve --port 4096 --hostname 0.0.0.0
```

Auth is HTTP Basic (username defaults to `opencode`). The Kit injects the `Authorization` header on both REST and the SSE stream.

### Claude Code via agentapi

```bash
agentapi server --port 3284 --type=claude -- claude
```

agentapi has **no authentication** — only host/CORS allowlists. Never expose port 3284 publicly.

## Security model

Run both servers bound to a private network. **Tailscale (plus `AGENTAPI_ALLOWED_HOSTS` for agentapi) is the firewall** — point the Kit at the tailnet IP. opencode adds HTTP Basic on top; agentapi relies entirely on the network boundary.

Credential storage is abstracted behind `SecretStore` (an `EnvironmentSecretStore` ships in the core). An app supplies a Keychain implementation; the core never imports `Security`.

## Cross-platform notes

- SSE uses [`mattt/EventSource`](https://github.com/mattt/EventSource) with the `AsyncHTTPClient` trait, because `URLSession.bytes` does not exist on Linux. REST uses `URLSession.data(for:)`, which does.
- No `UIKit`/`AVFoundation`/`Combine`/`Security`/`os` imports anywhere in `Sources/`. Logging goes through `swift-log`; an app bootstraps an OSLog backend, Linux uses stdout.

## Develop & test

```bash
scripts/test.sh              # swift build + swift test (sets Linux LD_LIBRARY_PATH)
swift test --filter OpenCodeReducerIntegrationTests
```

Decoder and reducer tests run offline against fixtures captured from a live opencode server and the agentapi schema.

## Documentation

```bash
swift package --disable-sandbox generate-documentation --target AgentCore
```

## License

MIT — see [LICENSE](LICENSE).
