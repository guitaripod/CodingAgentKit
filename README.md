# CodingAgentKit

A cross-platform Swift package for driving coding-agent servers over HTTP + SSE. It speaks two backends behind one unified model:

- **opencode** (`opencode serve`) — multi-provider, file browsing, diffs, permissions.
- **Claude Code** via a bridge service (e.g. claude-bridge) exposing structured sessions over HTTP + SSE — a subscription-billed Claude Code session.

It compiles, tests, and **runs on Linux and Apple platforms**. No Keychain, no OSLog, no UIKit anywhere in the core — so it works headless on a server as well as inside an iOS app.

## Why

Both opencode and Claude Code expose an HTTP surface with a Server-Sent Events stream. Their wire formats differ (opencode streams fine-grained part deltas; the Claude backend receives whole messages with deltas), but a client wants one transcript model to render. CodingAgentKit hides that difference behind a `CodingAgentBackend` protocol and a `MessageReducer` that folds either event style into one ordered `[ChatMessage]` — which is the reusable heart you can drop into a UIKit app, a CLI, or a TUI.

## Modules

| Product | Purpose |
|---|---|
| `AgentCore` | Transport (URLSession REST + SSE), unified models, `CodingAgentBackend`, `MessageReducer`, `AgentConversation`, protocols (`SecretStore`, `SessionCache`), swift-log facade. No backend specifics, no Apple-only imports. |
| `OpenCodeKit` | Hand-written opencode client + event decoder + `OpenCodeBackend` (conforms `FileBrowsingBackend`). |
| `ClaudeCodeKit` | Hand-written client for Claude Code bridge + event decoder + `ClaudeCodeBackend`, over an SSE stream. |
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
.package(url: "https://github.com/guitaripod/CodingAgentKit.git", from: "0.16.0")
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
- **Many observers, one connection** — every `states()` caller gets its own stream over a shared refcounted connection (two panes on one chat cost one socket), and `reconnect()` re-dials underneath live observers.
- **One socket per server** — against a protocol-2 bridge, `BridgeStream` multiplexes every conversation, the chat list and subagent activity over a single sequenced `/stream` connection with replay on reconnect, gap detection, and a heartbeat watchdog.
- **Approvals converge** — a permission answered on another device resolves the pending card everywhere; answered ids are remembered so it never re-prompts.

## Backend capabilities

Not every backend can do everything. Each backend declares a `BackendCapabilities` value; gate UI on it rather than on the concrete type. Calling an unsupported *action* method throws `AgentError.unsupported`; the optional *read* methods (`usageQuota()`, `sessionUsage(_:)`, `sessionSpend(_:)`, `usageAnalytics(days:)`, `subagents(for:)`, `availableAgents()`) instead return `nil`/empty when unsupported. `searchTranscripts(_:limit:)` throws `AgentError.unsupported` — gate it on `supportsTranscriptSearch`.

Beyond the flags, capability is also expressed as protocols a backend conforms to: `FileBrowsingBackend` (listing + content), `GitObservingBackend` (`gitSnapshot`/`gitPatch`/`gitCommit` — the project's repository, read but never operated), `AuthenticatingBackend` (`ServerAuth` — the split browser sign-in below), and `SelfUpdatingBackend` (`ServerUpdate` — a server that reports what it runs vs. what it could run, and updates itself through its own restart, `restartRequired` and all). Check conformance with `as?`.

Model and reasoning effort are chosen **per prompt** via `SendPrompt.model` / `SendPrompt.reasoningEffort`, not applied as a standing session setting.

| Capability | Flag | opencode | Claude Code (claude-bridge) |
|---|---|:-:|:-:|
| File browsing (`FileBrowsingBackend`) | `supportsFileBrowsing` | ✅ | ✅ ¹ |
| Diffs | `supportsDiffs` | ✅ | — |
| Permission prompts | `supportsPermissions` | ✅ | — |
| Structured questions | `supportsQuestions` | ✅ | ✅ ² |
| Multiple sessions | `supportsMultipleSessions` | ✅ | ✅ |
| Model selection (per prompt) | `supportsModelSelection` | ✅ | ✅ |
| Attachments (files/images in prompts) | `supportsAttachments` | ✅ | ✅ |
| Reasoning effort (per prompt) | `supportsReasoningEffort` | ✅ (per-model) | ✅ (low/medium/high/xhigh/max/ultracode) |
| Clear conversation in place | `supportsClearing` | — | ✅ |
| Fork session (branch with same history) | `supportsForking` | — | ✅ (bridge `--fork-session`) |
| Rename session | `supportsRenaming` | — | ✅ |
| Abort current turn | `supportsAbort` | ✅ | ✅ |
| Session usage (per-turn cost/tokens) | `supportsSessionUsage` | — | ✅ |
| Whole-session spend report | — ⁴ | — | ✅ |
| Account-wide usage analytics | `supportsUsageAnalytics` | — | ✅ |
| Transcript search (whole machine) | `supportsTranscriptSearch` | — | ✅ |
| Subagents (sidecar transcripts) | `supportsSubagents` | ✅ | ✅ |
| Server-side slash commands | `supportsCommands` | ✅ | ✅ |
| Goals (`/goal`, run until a condition holds) | `supportsGoals` | — | ✅ |
| Compaction as a transcript event | `supportsCompaction` | — | ✅ |
| Live usage quota (rate-limit gauges) | — ³ | — | ✅ |

¹ The Claude bridge serves file listing and content (`listFiles`/`fileContent`); `diff`, `find`, and `providers` have no bridge equivalent yet and return empty.
² The bridge's questions arrive in the transcript rather than as a protocol prompt, and `answersQuestionsByMessage` is `true`: answer by sending an ordinary message, not by calling a respond endpoint. `QuestionRequest.awaitingAnswer` derives what is still open from the transcript.
³ No `BackendCapabilities` flag — probe by calling `usageQuota()` / `additionalUsageQuotas()`, which return `nil`/empty when the backend has no usage API.
⁴ Probe by calling `sessionSpend(_:)`, which returns `nil` when the backend cannot price a conversation.

### Beyond messages

A transcript is more than text and tool calls, and the Kit models the rest as first-class parts and reads rather than leaving them for each client to re-derive:

- **`Compaction`** — a context compaction is a seam in the conversation: tokens before/after, how long it took, how many messages carried over, and the CLI's own summary. It arrives as a `MessagePart`, not as a wall of prose in the chat.
- **`QuestionRequest`** — structured multi-question, multi-option asks with free-text "Other", plus the transcript-derived answer state above.
- **Subagents** — `subagents(for:)` and `subagentMessages(sessionID:agentID:)` fetch a spawned agent's own transcript, keyed back to the tool call that spawned it.
- **`AgentCommand`** — what a turn will actually resolve on that machine: built-ins, user, project and plugin commands, with argument hints.
- **`SessionGoal`** — a `/goal` in flight, whether it was met or failed, and what it cost.
- **Tool-call summaries** — `ToolCallSummary` turns raw tool JSON into the line a human wants to read ("Read `ReconnectScheduler.swift` · 148 lines"), so clients don't each write their own.
- **`SessionSpendReport`** — the whole conversation priced turn by turn across the four token tiers, provenance stated, always an estimate; `UsageAnalyticsReport` widens it to the machine's month — daily buckets, models, projects, tools, what caching saved, records.
- **Git, read** — `GitSnapshot` (branch, upstream drift, triageable status, recent commits, half-done merges), `GitPatch`, `GitCommitDetail` — via `GitObservingBackend`.
- **`ServerAuth`** — a signed-out server as a state: `beginSignIn()` returns the status carrying the OAuth URL the machine printed, `submitSignInCode(_:)` hands over the code the browser produced and returns the signed-in status. The sign-in happens on the server; the person happens wherever they are.
- **`ServerUpdate`** — what a server runs vs. what it could run, with the honesty baked into the type: the running binary's own stamp beside the checkout's, `restartRequired`, and a `RemoteCheck` that can say "the remote was never reached" instead of "up to date".
- **`TurnInterruption`** — a turn the machine cut off, as data: the progress its transcript proves (tools, files, commands, partial answer), what queued behind it, whether it has been resumed.
- **Live compaction** — `ConversationState.activeCompaction` carries a compaction as it runs (and keeps it running while a prompt queues behind it), so a client can show the seam being made, not just the seam.
- **`listAllSessions(knownDirectories:)`** — the complete machine-wide listing, subagent sidecar sessions excluded (`AgentSession.isSubagent`), for the client that lists every chat on every server.

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

Config resolves from flags, then environment: `OPENCODE_HOST`, `OPENCODE_SERVER_PASSWORD`, `OPENCODE_SERVER_USERNAME`, `BRIDGE_HOST`, `BRIDGE_PASSWORD`, with `CODEAGENT_PASSWORD` as the backend-agnostic fallback.

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

- SSE streams over native `URLSession.bytes` on Apple platforms and [`AsyncHTTPClient`](https://github.com/swift-server/async-http-client) on Linux (where `URLSession.bytes` does not exist), both feeding the package's own incremental `SSEParser`. REST uses `URLSession.data(for:)`, which exists everywhere.
- No `UIKit`/`AVFoundation`/`Combine`/`Security`/`os` imports anywhere in `Sources/`. Logging goes through `swift-log`; an app bootstraps an OSLog backend, Linux uses stdout.
- Every string the Kit puts in front of a person — error messages, tool-call summaries, status fallbacks — resolves through `AgentText` against `AgentCore`'s own `Localizable.xcstrings`, so a localized app doesn't get English leaking out of its engine.

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

- [Tailscode](https://github.com/guitaripod/Tailscode) — native clients for iOS (UIKit), Linux (GTK4) and macOS (AppKit), all built on this Kit.
- [claude-bridge](https://github.com/guitaripod/claude-bridge) — the structured HTTP/SSE bridge for Claude Code that `ClaudeCodeKit` speaks to.

## License

GPL-3.0 — see [LICENSE](LICENSE).
