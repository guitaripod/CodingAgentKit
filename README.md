# CodingAgentKit

A cross-platform Swift package for driving coding-agent servers over HTTP + SSE. It speaks two backends behind one unified model:

- **opencode** (`opencode serve`) — multi-provider, file browsing, diffs, permissions.
- **Claude Code** via a bridge service (e.g. claude-bridge) exposing structured sessions over HTTP + SSE — a subscription-billed Claude Code session.

It compiles, tests, and **runs on Linux and Apple platforms**. No `URLSession.bytes`, no Keychain, no OSLog in the core — so it works headless on a server as well as inside an iOS app.

## Why

Both opencode and Claude Code expose an HTTP surface with a Server-Sent Events stream. Their wire formats differ (opencode streams fine-grained part deltas; the Claude backend receives whole messages with deltas), but a client wants one transcript model to render. CodingAgentKit hides that difference behind a `CodingAgentBackend` protocol and a `MessageReducer` that folds either event style into one ordered `[ChatMessage]` — which is the reusable heart you can drop into a UIKit app, a CLI, or a TUI.

## Modules

| Product | Purpose |
|---|---|
| `AgentCore` | Transport (URLSession REST + SSE), unified models, `CodingAgentBackend`, `MessageReducer`, `AgentConversation`, protocols (`SecretStore`, `SessionCache`), swift-log facade. No backend specifics, no Apple-only imports. |
| `OpenCodeKit` | Hand-written opencode client + event decoder + `OpenCodeBackend` (conforms `FileBrowsingBackend`). |
| `ClaudeCodeKit` | Hand-written client for Claude Code bridge + event decoder + `ClaudeCodeBackend`, with an SSE stream and a polling fallback. |
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
.package(url: "https://github.com/guitaripod/CodingAgentKit.git", from: "0.6.5")
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

let session = try await backend.createSession(title: nil, directory: nil)
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

### Resilience

`AgentConversation` is built to survive real-world sessions on flaky links:

- **Auto-reconnect with backoff** — the event stream reconnects with capped exponential backoff + jitter, and every gap is healed with a catch-up `messages(for:)` refresh.
- **Status inference from streaming** — opencode never sends an explicit "running" status, so streaming activity on an unfinished assistant message flips the state to `.running` on its own; clients always see a busy indicator.
- **Transcript-derived status recovery** — status events that fired while disconnected are gone forever, so after every refresh the transcript is the source of truth: a completed or visibly-streaming last message corrects a stale status.
- **Divergence recovery** — a text delta for a part the reducer has never seen means the local transcript diverged from the server's (a reconnect gap); instead of fabricating a bubble that starts mid-response, the delta is dropped and the transcript re-fetched.
- **Session cache** — plug in a `SessionCache` (a pure-Foundation `FileSessionCache` ships in the core) and cold starts render instantly from disk while the live transcript loads; snapshots persist at turn boundaries.

## Backend capabilities

Not every backend can do everything. Each backend declares a `BackendCapabilities` value; gate UI on it rather than on the concrete type. Calling an unsupported method throws `AgentError.unsupported`.

| Capability | opencode | Claude Code (claude-bridge) |
|---|:-:|:-:|
| File browsing (`FileBrowsingBackend`) | ✅ | — |
| Diffs | ✅ | — |
| Permission prompts | ✅ | — |
| Multiple sessions | ✅ | ✅ |
| Model selection | ✅ | ✅ (persistent, via `/model`) |
| Attachments (files/images in prompts) | ✅ | — |
| Reasoning effort (low/medium/high) | — | ✅ (via `/effort`) |
| Clear conversation in place | — | ✅ (via `/clear`) |
| Fork session (branch with same history) | — | ✅ (bridge `--fork-session`) |
| Abort current turn | ✅ | — |
| Session usage (per-turn cost/tokens) | — | ✅ |

## Discovering servers on a tailnet

You don't have to type IP addresses. `AgentCore` ships discovery primitives:

- **`ConnectionProbe`** classifies any base URL: `.ok(agentType:version:)` (auto-detects opencode vs the Claude bridge from `/global/health` vs `/status`), `.authFailed`, `.unreachable`, or `.notAnAgentServer`. Unreachable probes are retried once. This is what `codeagent discover` uses.
- **`TailscaleClient`** fetches your tailnet's devices from the Tailscale API, with either OAuth client credentials or a raw API token (`tskey-api-…`).
- **`TailnetScanner`** probes every device's addresses and hostname on the agent ports (default `4096`/`4098`, up to 16 concurrent probes) and returns ready-to-connect `Suggestion`s — backend type, version, and whether a password is required — deduplicated to one per server, preferring hostname-addressed, no-auth entries.

```swift
let devices = try await TailscaleClient().fetchDevices(with: "tskey-api-…")
let suggestions = await TailnetScanner().scan(devices: devices)
for s in suggestions {
    print("\(s.name) → \(s.baseURL) (\(s.backend))\(s.requiresAuth ? " 🔒" : "")")
}
```

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

Config resolves from flags, then environment: `OPENCODE_HOST`, `OPENCODE_SERVER_PASSWORD`, `OPENCODE_SERVER_USERNAME`, `BRIDGE_HOST`, `BRIDGE_PASSWORD`.

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

### Claude Code

A bridge service exposing Claude Code via the structured HTTP/SSE API used by `ClaudeCodeBackend` (typical port 4098). Configure with `BRIDGE_HOST` and `BRIDGE_PASSWORD` (Basic auth user "claude").

The service is reached over a private network (Tailscale recommended). Never expose publicly.

## Security model

Run both servers bound to a private network. **Tailscale is the firewall** — point the Kit at the tailnet IP. opencode adds HTTP Basic on top; the Claude bridge relies on the network boundary (and optional Basic auth).

Credential storage is abstracted behind `SecretStore` (an `EnvironmentSecretStore` ships in the core). An app supplies a Keychain implementation; the core never imports `Security`.

## Cross-platform notes

- SSE streams over native `URLSession.bytes` with an incremental `SSEParser` on Apple platforms; on Linux (where `URLSession.bytes` does not exist) it falls back to [`mattt/EventSource`](https://github.com/mattt/EventSource) with the `AsyncHTTPClient` trait. REST uses `URLSession.data(for:)`, which exists everywhere.
- No `UIKit`/`AVFoundation`/`Combine`/`Security`/`os` imports anywhere in `Sources/`. Logging goes through `swift-log`; an app bootstraps an OSLog backend, Linux uses stdout.

## Develop & test

```bash
scripts/test.sh              # swift build + swift test (sets Linux LD_LIBRARY_PATH)
swift test --filter OpenCodeReducerIntegrationTests
```

Decoder and reducer tests run offline against fixtures captured from a live opencode server and the Claude bridge schema.

## Documentation

```bash
swift package --disable-sandbox generate-documentation --target AgentCore
```

## Used by

- [Tailscode](https://github.com/guitaripod/Tailscode) — native UIKit iOS client for remote coding agents over Tailscale, built on this Kit.
- [claude-bridge](https://github.com/guitaripod/claude-bridge) — the structured HTTP/SSE bridge for Claude Code that `ClaudeCodeKit` speaks to.

## License

GPL-3.0 — see [LICENSE](LICENSE).
