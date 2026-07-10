# Changelog

## Unreleased

### Added
- Tailnet discovery: `TailscaleClient` (fetch tailnet devices via the Tailscale API, OAuth client
  credentials or raw API token) and `TailnetScanner` — probes every device's addresses and hostname
  on the agent ports (default 4096/4098, up to 16 concurrent probes) and returns ready-to-connect
  `Suggestion`s (backend, version, auth requirement), deduplicated per server with hostname-addressed,
  no-auth entries preferred.
- `supportsAbort` and `supportsSessionUsage` on `BackendCapabilities` (opencode sets abort; Claude
  sets usage).
- Status inference from streaming: `AgentConversation` flips to `.running` on streaming activity
  against an unfinished assistant message (opencode never sends an explicit running status), and the
  opencode decoder maps `step.started` → running.
- Transcript-derived status recovery: after every refresh the transcript corrects a stale status
  (completed last message → idle, visibly-streaming → running), since status events that fired while
  disconnected are gone forever.
- Divergence recovery: a text delta for an unknown part (reconnect gap) triggers a quiet re-fetch
  instead of fabricating a message bubble that starts mid-response.
- Native SSE on Apple platforms: incremental `SSEParser` over `URLSession.bytes` with a dedicated
  stream session whose bounded inter-byte timeout detects half-open sockets (app suspension, dead
  VPN tunnels); Linux keeps `EventSource` + AsyncHTTPClient.

### Changed
- **License changed from MIT to GPL-3.0.**
- Standardized on `ClaudeCodeBackend` (previously `ClaudeSDKBackend` internally). README now accurately describes the claude-bridge structured service for Claude Code support (with `BRIDGE_HOST`/`BRIDGE_PASSWORD`).
- `createSession(title:)` is now `createSession(title:directory:)` so opencode sessions can be opened in a specific working directory.
- `BackendFailure` gains optional `detail`; reconnect paths now use `LocalizedError` descriptions where available.
- `states()` buffers only the newest snapshot (`bufferingNewest(1)`); cache persists are chained so
  writes land in order.

### Fixed
- `ConnectionProbe` retries unreachable probes once and validates the health/status payload shape
  instead of classifying any 200 response as an agent server.
- Tailscale OAuth token exchange form-encodes client credentials correctly (`+`, `&`, `=` in a
  secret no longer corrupt the request body).
- `FileSessionCache` filename sanitizing is collision-free (digest suffix for IDs with disallowed
  characters).
- `ConnectionProfileStore` no longer wipes stored profiles on a transient read failure
  (data-protection lock), and writes the Keychain password before the profile lands on disk.
- Claude bridge messages with duplicate part ids get index suffixes so `messageID:partID` row
  identifiers stay unique while streaming deltas still route to the first part.
- opencode event decoder reads the session id from nested `info`/`part` payloads too, so
  cross-session events are filtered correctly.
- `JSONValue.compactDescription` no longer traps on numbers that exceed `Int` range.
- CLI `send` subscribes to the event stream before sending, so the first tokens of a reply are never
  dropped; SSE hang, URL construction, and dead polling-path bugs fixed.
- Documentation drift around Claude backend (agentapi references and examples corrected to match bridge implementation).

## 0.6.5

### Added
- `BackendCapabilities.supportsForking` and `CodingAgentBackend.forkSession(_:)` (default throws
  unsupported) — branch a session into a new one seeded with the same history. The Claude backend
  forks via `POST /sessions/:id/fork` (bridge `--fork-session`).

## 0.6.4

### Fixed
- Tool input is passed through to `ToolCall.input`, enabling diff rendering of edits.

## 0.6.3

### Added
- `sessionUsage(_:)` + `AgentUsage` — per-turn cost/token usage where the backend reports it
  (Claude bridge).

## 0.6.2

### Added
- Bridge reasoning parts are mapped (Claude extended thinking renders as reasoning parts).

## 0.6.1

### Removed
- Dead agentapi Claude transport (`AgentAPIClient`, TUI-scrape mapping/decoder and their tests) now
  that Claude Code runs through the bridge. The CLI migrates to the bridge.

## 0.6.0

### Added
- Structured Claude Code backend via **claude-bridge**, replacing agentapi TUI-scraping: real
  resumable multi-sessions, token streaming, tool calls, per-turn model/effort, and clear.
- `SendPrompt.reasoningEffort`, threaded through `AgentConversation.send`.
- `ConnectionProbe` detects the bridge.

## 0.5.0

### Added
- `supportsClearing` + `clearConversation` (Claude sends `/clear`); `createSession` clears so a new
  chat starts fresh rather than reopening the persistent session.

### Fixed
- Claude terminal chrome is stripped (banner, status bar, MCP/usage callouts, slash-command echoes,
  ephemeral thinking spinner) so chat rows keep a stable height instead of reflowing on every
  terminal redraw.

## 0.4.0

### Added
- Claude Code model + reasoning-effort selection: `supportsReasoningEffort`, opus/sonnet/haiku model
  aliases and low/medium/high effort levels, each applied immediately as a persistent session
  setting rather than a per-message parameter.

## 0.3.2

### Fixed
- The Claude Code backend honors the basic-auth password (credentials were dropped, so any
  authed server returned 401).

## 0.3.1

### Fixed
- `AgentConversation` loads the existing transcript before streaming, so opening a session with
  prior messages no longer shows empty (the opencode event stream is live-only).

## 0.3.0

### Added
- `CodingAgentBackend.deleteSession(_:)` with a default unsupported implementation; the opencode
  backend implements `DELETE /session/{id}`, `MockBackend` gets a no-op.
- `OpenCodeEventDecoder` and the Claude event decoder are public, usable for replay and tests.

## 0.2.0

Turns the Kit from a networking library into an app foundation: a unified, observable
conversation state; resilient reconnection; and testability without a live server.

### Added
- `ConversationState` + `AgentConversation.states()` — a single `AsyncStream` snapshot
  (messages, status, pending permissions, last failure, connection phase) for a UIKit view
  controller to consume with `for await`.
- Auto-reconnecting event stream: capped exponential backoff + jitter, catch-up refresh via
  `messages(for:)`, and an SSE→polling fallback for the Claude backend.
- `AgentConversation.respond(to:decision:)` and `cancelCurrentTurn()`; permission prompts are now
  surfaced instead of dropped.
- Typed `BackendFailure { message, code, retryable }`.
- `ConnectionPolicy` on `ServerConfig` (request/resource timeouts + reconnect tuning); requests now
  time out instead of hanging on URLSession's 60s default.
- `ConnectionProbe` — classify a URL (ok/authFailed/unreachable/notAnAgentServer) and auto-detect
  the backend. New `codeagent discover`.
- File/image attachments in prompts (`SendPrompt.attachments`, opencode). New `codeagent send --attach`.
- Model discovery on the backend protocol: `availableModels()`, `availableAgents()`,
  `defaultModel()`; `ModelSelection(string:)` / `rawValue` in AgentCore.
- `Codable` across the core models; `FileSessionCache` (pure FileManager/JSON) wired into
  `AgentConversation` for instant cold-start (seed on start, persist on turn boundaries).
- New products: `AgentTestSupport` (`MockBackend` + SSE replay helpers) and `CodingAgentKitApple`
  (`KeychainSecretStore`, `ConnectionProfile`, `ConnectionProfileStore`).

### Changed
- macOS minimum raised to 15 to pair with iOS 18 (enables `Synchronization.Mutex`).
- `BackendEvent.failure` now carries `BackendFailure`; the two event decoders are `public`.

### Fixed
- SSE connection/transport errors are surfaced to the caller instead of hanging forever.
- `AgentConversation` no longer silently drops status/permission/failure events.

## 0.1.0

Initial release: `AgentCore` + `OpenCodeKit` + `ClaudeCodeKit`, the `codeagent` CLI, and the
unified `MessageReducer`. Builds and tests on Linux and Apple; verified live against opencode 1.17.13.
