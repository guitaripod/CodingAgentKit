# Changelog

## 0.15.0

Being connected is something the socket says, and a turn the machine cut off is a state a client can read.

### Added
- **`TurnInterruption` reaches the client.** `ConversationState.interruption` carries a turn the
  server's own machine cut off — fetched on every refetch and delivered live as a `BackendEvent`,
  so a client that was not connected when the server noticed still finds out.
  `ClaudeCodeBackend` reads `/sessions/:id/interruption` and posts resume/dismiss;
  `AgentConversation.resumeInterruptedTurn()` / `dismissInterruptedTurn()` drop the record only on
  the server's answer. `InterruptionReading` keeps "nothing was interrupted" and "this server
  cannot say" apart, and only the former may clear a standing card.
- **`BackendEvent.attached`: the transport states that it is open.** Emitted on the bridge's hello,
  on every heartbeat, and to a session subscribing onto a socket somebody else opened.
- **`ConversationState.connectionChangedAt`**, so a surface can say how long a phase has been true.

### Fixed
- **A healthy idle conversation reported "connecting" forever.** `markLive` was reachable only
  from inside the event loop on a non-buffered event, and the bridge's hello and heartbeat frames
  were swallowed by `BridgeStream.handle` before any session subscriber saw them — so a chat
  nobody was talking in heard nothing at all off a perfectly good socket. A chat opened during its
  own first transcript fetch had the same fate for a different reason: the buffer's `continue` sat
  above the `markLive` it needed. Anything off the transport now marks live before the buffer
  decides what to do with it, and a transcript fetch that succeeds upgrades `connecting` to
  `live` — only ever out of `connecting`, so a dropped stream keeps saying `reconnecting`.

## 0.14.1

An opencode chat that lives outside the server's launch project streams again.

### Fixed
- **Live events for sessions rooted outside every known project worktree.** A chat under
  `$HOME` (or any directory the server did not list as a project) still accepted prompts — the
  GPU worked — but the client's `/event` subscription used a nil directory, so the unscoped
  stream stayed silent and the UI never moved. Directory lookup now falls back to
  `GET /session/:id`, caches directories from `listAllSessions`, and a turn is marked running as
  soon as `prompt_async` returns so a dead stream still trips the stale-transcript refresh.

## 0.14.0

A turn that finished having said nothing is a fact the transcript can state.

### Added
- **`ChatMessage.isAnswerless`: the turn that produced nothing at all.** A provider that refuses a
  request mid-stream can end a turn with no words, no tool call, no picture, no error and zero
  tokens — the message carries only the turn's own step markers. Every transcript is built from
  what a turn produced, so that outcome draws nothing anywhere: the status goes from running to
  idle, no failure event is ever emitted, and the whole turn is invisible to a reader who watched
  a spinner stop. The property names it from the message itself — assistant, completed, no error,
  and not one part carrying content — and excludes a turn somebody stopped by hand, whose
  emptiness they already understand. `carriesAnswer` is the same question about content alone.
- **`ChatMessage.finishReason`: the backend's own word for how a turn ended**, verbatim and never
  translated, so a client can quote it rather than guess at it. opencode reports `unknown` for a
  stream that ended without saying why, which is exactly the ending an answerless turn has.

## 0.13.1

A compaction that is still running stays running while a message queues behind it.

### Fixed
- **A prompt sent while a compaction runs no longer ends the compaction — on screen only.** A new
  turn cleared the standing ``CompactionActivity`` outright, so queueing a message behind a
  minutes-long summarize took the "compacting" surface off screen while the machine was still
  compacting, with no event coming until it finished. Only an attempt that is *over* — the failure
  a reader has already been shown — stops being current state when a prompt goes out.

## 0.13.0

A delta that knows which paragraph it belongs to, and a name for a turn the machine cut off.

### Added
- **`TurnInterruption`: the shape a turn killed by the machine reads in.** A backend process that
  dies mid-turn leaves a conversation that looks finished — the prompt is there, no answer
  follows, nothing says one was ever coming — and that is the one ending a client must never
  render as silence. The value carries what the turn had already done before the power went
  (tools, files touched, commands run, how far the answer had got), the prompts that queued behind
  it and never ran, and whether the work has since been picked back up.

### Fixed
- **A delta is written into the block the message is being written into, not into one named by a
  counter.** A claude-bridge delta carries no part id, so the client invented one from a
  per-process counter that any stream gap resets: a fresh decoder meeting a transcript that
  already held `["text", <tool>, "text-1"]` named `"text"`, which exists, and the answer was
  written into the first paragraph, above the tool rows. `partID: nil` now means "the block this
  message is being written into" and the reducer resolves it against the transcript it actually
  holds, which is the only thing that knows.
- **A refetch no longer forgets what arrived while it was out.** An actor is re-entrant across an
  await, so every refresh kept applying events while suspended and then rebuilt them away — the
  stale-turn nudge, the recovery fetch and the reconnect all did. Refreshes buffer and replay
  through one path, a message the stream is writing keeps the version this device has, and where
  the two accounts overlap without either containing the other the buffer is credited with the
  longest opening the server's text already ends with.
- **An opencode session has been naming its model all along, and nobody read it.** The session
  record's own model is mapped through, so a row can say what answered it without a round trip.

## 0.12.0

A server that says what it is running, and what it could not find out.

### Added
- **`ServerUpdate` reports the running binary, not only the checkout.** `version` describes a
  *directory* — it moves when somebody checks out a branch there, and it runs ahead of the process
  for the whole stretch between a build and a restart, which under a machine with no service to
  restart it is permanent. `running`, `builtAt` and `restartRequired` are facts about the program
  that is answering, so a client can say "built, not restarted" instead of calling it current.
- **`ServerUpdate.RemoteCheck`: whether the server consulted the project, and whether that
  worked.** `updateAvailable: false` used to mean four different things a client could not tell
  apart — genuinely current, asked not to check, no checkout to check with, and a fetch that
  failed silently — and only one of them is "up to date". The block carries `checked`, `ok`, when
  it was read, why it failed in words worth showing a person, and the `ref` it compared against,
  so a machine deliberately on a feature branch is not counted as behind everyone else's master.
- **`ServerUpdate.ahead`.** An update is a fast-forward, so a checkout with commits of its own
  cannot take one however willing the rest of the status looks.

### Fixed
- **A phase this version has never heard of no longer discards the whole status.** `Phase` decodes
  through its raw string and falls back to `.idle`, so a newer server naming a new phase degrades
  to "nothing in flight" rather than failing the decode and blanking the surface.

## 0.11.1

### Fixed
- **An agent a conversation spawned is not a conversation.** opencode gives a spawned agent a
  session of its own, parented to the one that spawned it, and it was listed as a chat somebody
  had — the same work present twice, once as the conversation that asked for it and once as a
  chat nobody started. `listAllSessions(knownDirectories:)` is the conversation listing and now
  drops parented sessions in every backend, and the bridge's live session stream never upserts
  one. `listSessions()` stays the server's literal listing, so a subagent's spend is still
  counted where usage is totalled, and `AgentSession.isSubagent` says which is which.

## 0.11.0

What a conversation cost, every session a machine holds, and streaming that stops copying the
answer to grow it.

### Added
- **`SessionSpendReport`: a backend can account for what a conversation cost.** Not the last
  turn's price but the whole conversation, turn by turn, with tokens split by the tier that
  prices them — cache reads are an order of magnitude cheaper than fresh input and cache writes
  cost more than either. The Claude backend reads it from the bridge (which reads the CLI's own
  transcript); every other backend answers nil and the client falls back to what its transcript
  admits. The report carries whether its money was priced or reported, because a subscription
  bills a flat fee and an estimate presented as a bill is a lie.
- **opencode: a complete listing.** opencode scopes `/session` to the project its server was
  launched in, so the plain listing was one project's history presented as the machine's. The
  listing is now a walk — the server's own project, every project it knows, and the directories
  sessions have been seen working in — deduplicated by id, six scopes at a time.
- **opencode: a picture arrives with its bytes**, the same `file` part + raw-bytes fetch the
  bridge already had, instead of images being a bridge-only capability.
- **The demo catalog is a real machine's mix of commands**, so a client's completion UI is
  exercised by realistic namespaces rather than a toy list.

### Fixed
- **An answer is grown, not copied.** Appending a streaming delta did `value + delta` while the
  enum case still held the original, so every arrival reallocated the whole answer — a hundred
  thousand characters arriving in two thousand lumps copied a hundred million characters of
  garbage. The string is taken out of the case first, leaving it uniquely referenced so the
  append is amortized O(1). A tool call's one-line name is also no longer recomputed as if it
  were a summary on every reconfigure.
- **An opencode rate-limit retry is a wall the app can see, not a silence.** opencode parks a
  turn in `session.status` `retry` when a provider quota is spent; the decoder dropped the
  event, so the chat read as an eternal running timer. `retry` now maps to a retryable failure
  carrying the provider's message, which lights the existing quota wall in every client.

## 0.10.0

The release that lets more than one window watch one conversation, and one socket carry a whole
server.

### Added
- **Many observers on one conversation.** `states()` no longer tears down whatever came before it:
  every caller gets its own stream over one shared connection, refcounted so the run loop starts
  with the first observer and stops with the last. A chat window, a second window and a session
  list can watch the same session at once. `reconnect()` re-dials underneath the observers without
  ending anyone's stream — the forced reconnect that calling `states()` twice used to provide.
- **`permissionResolved`.** `pendingPermissions` was the one field in `ConversationState` that
  could not converge; an approval answered on the phone stayed live on the desktop forever.
  Decoded from opencode's replied/rejected/updated shapes, with answered ids remembered so a late
  re-ask cannot resurrect a settled card.
- **`BridgeStream`: one socket per server.** Multiplexes the bridge's proto-2 `/stream` with
  replay, gap detection and a heartbeat watchdog, instead of a connection per session.
- **`SubagentSummary` carries live progress**, so a fan-out can be rendered while it runs.
- **A spend gauge carries its money.** `usedUSD` / `limitUSD` pass through the bridge quota.
- **Per-model effort on opencode.** Effort variants ride the catalog, the send, and the
  transcript, rather than being one setting for every model.
- **Every account the machine holds.** Extra quotas are fetched for all of them, not just the
  first.
- **Ultracode joins the effort menu, Opus 1M joins the catalog.** Ultracode is a mode more than a
  level — the server reads it as xhigh plus standing multi-agent orchestration — so it belongs in
  the same list clients already render.
- **`AuthenticatingBackend` + `ServerAuth`.** Whether the agent behind a server is signed in, and
  the three-step browser sign-in that fixes it when it isn't: `beginSignIn()` returns the URL the
  server printed, `submitSignInCode(_:)` hands back the code it produced. `ClaudeCodeBackend`
  conforms; a bridge without the routes throws `AgentError.unsupported`.
- **`SelfUpdatingBackend`.** A server that can install its own updates: `updateStatus(checkingRemote:)`
  reports the running version, whether the remote is ahead and by which commits, and whether this
  install can move at all; `startUpdate()` asks it to. `ClaudeCodeBackend` conforms — a bridge too
  old to know the route throws `AgentError.unsupported`. `ServerUpdate.phase` follows a run through
  the server's own restart, so a client can keep watching something that stops answering.
- **`health()` reports the bridge's version.** It reads `/status`, which costs the same round trip
  as `/health` and carries what the server is actually running, instead of the constant `"claude"`.

### Fixed
- **Attachment URLs may carry a query string.** `ClaudeCodeBackend.attachmentData` now splits a
  relative bridge URL into path and query items instead of handing the whole string to
  `appendingPathComponent`, which percent-encoded the `?` and 404'd. Lets the bridge address
  attachment bytes by file path (`/files/raw?path=…`) — the shape it uses for a picture the agent
  read — not only by stored attachment name.
- **A bridge upgraded mid-flight reaches running apps.** The proto is re-probed and list streams
  wait for it, instead of a live app staying on the old protocol until relaunch.
- **A person never reads `Error Domain=NSURLErrorDomain`.** Transport failures are turned into
  situations a banner can state.
- **A streaming turn reaches the cache every few seconds**, not only when it goes idle.

### Performance
- **A freshly opened chat pays for its three fetches at once.** Transcript, questions and goal now
  race rather than running in single file; the chat paints when the slowest lands.

## 0.9.0

Attachments, compaction, structured questions, and the sessions of every worktree.

### Added
- **Image and file attachments** for claude-bridge sessions, with `attachmentData` to fetch the
  bytes through the backend and per-model input capabilities on `ModelInfo`.
- **Compaction as a first-class conversation event**, so a client can render the seam instead of
  the summary.
- **Structured questions, server commands and goals** in the Kit.
- **Every worktree's sessions**, not just the server's own.
- **Semantic tool-call summaries** for presentation, and the Kit's own errors and fallbacks spoken
  in the reader's language.
- **A session is live when its agents are**, not only when its own turn is.

### Fixed
- Stale running status surviving a finished turn.

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
