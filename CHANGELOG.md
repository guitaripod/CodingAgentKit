# Changelog

## 0.8.0

### Added
- **Device push registration.** `CodingAgentBackend` gains `registerDeviceToken(_:)` /
  `unregisterDeviceToken(_:)` with a new `DevicePushRegistration` payload (`token`, `environment`),
  mirroring the Live Activity registration pattern: empty no-op defaults so OpenCode/Mock conformers
  are unaffected, and a `ClaudeCodeBackend` implementation posting to the bridge's
  `/push/device` and `/push/device/unregister` routes. Lets an app hand its APNs device token to
  every connected claude-bridge so the server can push turn-end alerts and usage refreshes.

## 0.7.0

Reliability and cross-platform hardening pass. The SDK is now verified building and passing its full
suite on both Linux (swift-corelibs-foundation) and Apple platforms.

### Fixed
- **Linux SSE no longer silently drops events.** The Linux event stream previously ran on
  `mattt/EventSource` with a default 60s idle timeout and hidden auto-reconnect that swallowed the
  `Last-Event-ID` and never told the consumer — so on the claude-bridge's idle-between-turns pattern,
  permission prompts, status transitions, and questions emitted during the gap were lost. Both
  platforms now feed one long-lived transport (Linux: `AsyncHTTPClient` directly; Apple:
  `URLSession.bytes`) through the package's own `SSEParser`, with a 300s inter-byte / 7-day total
  budget, and surface every stream end/error to `AgentConversation` so its reconnect + transcript
  repair runs. `EventSource` is no longer a dependency.
- `AgentConversation` reconnect loop classifies failures: permanent HTTP errors (401/403/404 and
  other non-retryable 4xx) now surface a terminal `.offline` state instead of retrying forever;
  transient/5xx/transport failures keep backoff. A terminal failure can no longer be clobbered by a
  late in-flight refresh.
- Initial-refresh and recovery-refresh races that could double-apply or silently drop streamed text
  deltas are reconciled deterministically.
- `MessageReducer` no longer loses `costUSD`/`totalTokens`/`providerID`/`modelID` when a
  metadata-free streaming update merges into an existing message; `snapshot` is now O(1) between
  mutations.
- Claude bridge event decoding routes text deltas to the currently-streaming text part (previously
  hardcoded to the first part, misplacing text after a tool call); `BRSummary`/`BRSession` tolerate
  missing `model`/`effort`/timestamps so one version-skewed field can't fail the whole session list.
- `SubagentTranscriptBackend` fetches the final transcript tail on completion and stops re-emitting
  the whole transcript every poll.
- opencode `totalTokens` now includes reasoning + cache tokens; `createSession` forwards its title.
- `SSEParser` handles a leading UTF-8 BOM and CR-only line terminators (WHATWG); `RequestBuilder`
  strictly percent-encodes query values (a `+` no longer decodes to a space server-side); Tailscale
  `preferred()` classifies IPv6 literals as addresses, not MagicDNS names.
- Session-cache files are written `0o600` (dir `0o700`) on every platform and, on iOS-family,
  encrypted at rest with `.completeUntilFirstUserAuthentication`.
- `CodingAgentKitApple`: connection-profile `baseURL` strips embedded `user:password@` credentials;
  the Keychain store pins the data-protection keychain with a this-device-only accessibility class;
  profile save/delete are serialized and transactional (no orphaned secret, no passwordless profile
  on partial failure).
- CLI: `codeagent diff`/`files`/`find`/`providers` gate on the backend's real capability flags
  instead of protocol conformance (no more false "(no changes)" on Claude); the send task is
  structured so a prompt can't be silently lost; `CODEAGENT_PASSWORD` avoids exposing the password
  on the command line.

### Added
- `JSONValue.integer(Int64)` — integers above 2^53 survive decode/encode round-trips instead of
  being coerced to `Double`.
- `AgentError.isRetryable` — lets consumers distinguish permanent from transient failures.
- `BridgeEventDecoder` is now `public`.
- `SendPrompt` is `Codable`/`Hashable`/`Sendable`.
- `ClaudeCodeKitTests` target; the suite grew from 43 to 146 tests, adding coverage for the Claude
  decoder/DTOs, SSE edge cases, request building, connection probing, session-cache robustness,
  and conversation failure paths.

## 0.6.7

### Added
- `AgentSession.model` and `AgentSession.reasoningEffort` — sessions now carry the model and effort
  they were created with, mapped from the Claude bridge's session summaries and full sessions. An
  empty effort from the bridge (discovered transcripts don't record one) maps to `nil` rather than
  implying the server default applied.

## 0.6.6

### Added
- Tailnet discovery: `TailscaleClient` (fetch tailnet devices via the Tailscale API, OAuth client
  credentials or raw API token) and `TailnetScanner` — probes every device's addresses and hostname
  on the agent ports (default 4096/4098, up to 16 concurrent probes) and returns ready-to-connect
  `Suggestion`s (backend, version, auth requirement), deduplicated per server with hostname-addressed,
  no-auth entries preferred. Scans now finish in seconds instead of minutes.
- Structured agent questions: `QuestionRequest` plus `answerQuestion`/`rejectQuestion`/
  `pendingQuestions` on the backend protocol and the `supportsQuestions` capability (opencode's
  question tool); `AgentConversation` surfaces them as `ConversationState.pendingQuestions`.
  opencode's `/event` and `/question` calls are now scoped by the session's workspace directory.
- Subagents as a first-class backend surface: `SubagentSummary`, `subagents(for:)` and
  `subagentMessages(sessionID:agentID:)`, the `supportsSubagents` capability, subagent
  active/completed state, and `ToolCall.spawnsSubagent`. The Claude bridge serves sidecar
  transcripts; other backends default to empty.
- Session renaming: `renameSession(_:title:)` + `supportsRenaming` (Claude bridge
  `PATCH /sessions/:id`), and full Claude model/effort coverage (opus/sonnet/haiku/fable aliases,
  low/medium/high/xhigh/max effort — all chosen per prompt via `SendPrompt`).
- File browsing for Claude: `ClaudeCodeBackend` conforms to `FileBrowsingBackend` over the bridge's
  `/files` routes (listing + content; `diff`/`find`/`providers` return empty for now) with
  `supportsFileBrowsing`.
- Live usage: per-message cost/tokens, live `UsageQuota` rate-limit gauges via `usageQuota()`, and
  `additionalUsageQuotas()` for other providers the host is signed into (e.g. Grok via the bridge's
  `/usage/grok`). `sessionUsage(_:)` reads a light `/usage` route with a full-transcript fallback.
- Live Activity hook: `LiveActivityRegistration` + `registerLiveActivity(_:for:)` so a backend can
  register an ActivityKit push token and drive Live Activity updates over APNs while suspended.
- `supportsAbort` and `supportsSessionUsage` on `BackendCapabilities` (opencode sets abort; Claude
  sets both, plus abort via `POST /sessions/:id/abort`).
- Transcript-load phase: `ConversationState.hasLoadedTranscript`/`isLoadingTranscript` distinguish a
  still-loading transcript from a genuinely empty conversation; concurrent session attach.
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
- `AgentSession.isActive` surfaces a live in-progress session; `AgentMarkup.strip` and
  placeholder-title detection (`isPlaceholderTitle`) help clients render and replace backend titles.
- `MockBackend` grows a full demo surface: interactive multi-turn replies, per-session scripts,
  injectable usage quotas, file trees, diffs, and subagent transcripts for previews and demos.

### Changed
- **License changed from MIT to GPL-3.0.**
- Standardized on `ClaudeCodeBackend` (previously `ClaudeSDKBackend` internally). README now accurately describes the claude-bridge structured service for Claude Code support (with `BRIDGE_HOST`/`BRIDGE_PASSWORD`).
- `createSession(title:)` is now `createSession(title:directory:)` so opencode sessions can be opened in a specific working directory; the Claude backend also tracks a per-session directory.
- `BackendFailure` gains optional `detail`; reconnect paths now use `LocalizedError` descriptions where available, and server error messages are surfaced from JSON error bodies.
- `states()` buffers only the newest snapshot (`bufferingNewest(1)`); cache persists are chained so
  writes land in order.

### Fixed
- A new prompt clears the previous turn's `lastFailure` so a stale error banner no longer lingers.
- `ConnectionProbe` retries unreachable probes once and validates the health/status payload shape
  instead of classifying any 200 response as an agent server.
- Tailscale OAuth token exchange form-encodes client credentials correctly (`+`, `&`, `=` in a
  secret no longer corrupt the request body); IPv6 hosts are handled.
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
