# Changelog

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
