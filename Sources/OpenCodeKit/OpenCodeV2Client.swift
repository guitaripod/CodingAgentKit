import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// opencode 2's HTTP API. Every route lives under `/api`; a route that reads or writes one
/// workspace is scoped by `location[directory]`, a session route is scoped by the session's own
/// record on the server, and the rest are process-wide.
public struct OpenCodeV2Client: Sendable {
    let builder: RequestBuilder
    let http: HTTPClient

    public init(config: ServerConfig, http: HTTPClient? = nil) {
        self.builder = RequestBuilder(config: config)
        self.http = http ?? HTTPClient(policy: config.policy, logger: AgentLog.logger("opencode2"))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw AgentError.decoding("\(T.self): \(error)")
        }
    }

    private func unwrap<T: Decodable & Sendable>(_ data: Data) throws -> T {
        let envelope: OC2Envelope<T> = try decode(data)
        return envelope.data
    }

    /// `location[directory]` names the workspace a scoped route answers for. Sent as the query
    /// item opencode reads first, so a caller never depends on a header a proxy might drop.
    static func locationQuery(_ directory: String?) -> [URLQueryItem] {
        directory.map { [URLQueryItem(name: "location[directory]", value: $0)] } ?? []
    }

    private static let emptyBody = Data("{}".utf8)

    func info() async throws -> OC2ServerInfo {
        try decode(await http.send(builder.request(.get, "/api/info")))
    }

    /// Every session the server holds, across every workspace, newest first. `parentID` of
    /// `"null"` asks for the conversations alone — a spawned agent's transcript is parented to
    /// the chat that spawned it — and a session id there asks for that chat's agents.
    func listSessions(limit: Int, directory: String? = nil, parentID: String? = nil) async throws
        -> [OC2Session]
    {
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let directory { query.append(URLQueryItem(name: "directory", value: directory)) }
        if let parentID { query.append(URLQueryItem(name: "parentID", value: parentID)) }
        let page: OC2Page<OC2Session> = try decode(
            await http.send(builder.request(.get, "/api/session", query: query)))
        return page.data
    }

    /// Which sessions have a turn open right now, process-wide.
    func activeSessions() async throws -> [String: OC2SessionStatus] {
        try unwrap(await http.send(builder.request(.get, "/api/session/active")))
    }

    func session(_ sessionID: String) async throws -> OC2Session {
        try unwrap(await http.send(builder.request(.get, "/api/session/\(sessionID)")))
    }

    func createSession(directory: String?) async throws -> OC2Session {
        let body = try JSONCoding.encoder.encode(
            OC2SessionCreateRequest(location: directory.map { .init(directory: $0) }))
        return try unwrap(await http.send(builder.request(.post, "/api/session", body: body)))
    }

    func deleteSession(_ sessionID: String) async throws {
        try await http.send(builder.request(.delete, "/api/session/\(sessionID)"))
    }

    func rename(_ sessionID: String, title: String) async throws {
        let body = try JSONCoding.encoder.encode(["title": title])
        try await http.send(builder.request(.patch, "/api/session/\(sessionID)", body: body))
    }

    func fork(_ sessionID: String) async throws -> OC2Session {
        try unwrap(
            await http.send(
                builder.request(.post, "/api/session/\(sessionID)/fork", body: Self.emptyBody)))
    }

    func projects() async throws -> [OC2Project] {
        try decode(await http.send(builder.request(.get, "/api/project")))
    }

    /// The whole transcript, oldest first. The route pages — newest first by default, fifty at a
    /// time — so it is walked with the cursor until a page comes back short. A cursor is only
    /// ever trusted beside a full page: the server hands one back on a page that already held
    /// everything, and following it would ask for the same page forever.
    func messages(sessionID: String) async throws -> [OC2Message] {
        var collected: [OC2Message] = []
        var cursor: String?
        while true {
            let page: OC2Page<OC2Message> = try decode(
                await http.send(
                    builder.request(
                        .get, "/api/session/\(sessionID)/message",
                        query: Self.messageQuery(cursor: cursor))))
            collected.append(contentsOf: page.data)
            guard page.data.count >= Self.messagePage, let next = page.cursor?.next, next != cursor
            else { break }
            cursor = next
        }
        return collected
    }

    static let messagePage = 200

    /// The first page names its order; every page after it names only the cursor, which carries
    /// the order inside it — the server refuses a cursor beside an order as a contradiction.
    static func messageQuery(cursor: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "limit", value: "\(messagePage)")]
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        } else {
            query.append(URLQueryItem(name: "order", value: "asc"))
        }
        return query
    }

    func prompt(sessionID: String, request: OC2PromptRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(builder.request(.post, "/api/session/\(sessionID)/prompt", body: body))
    }

    /// The model is a standing setting on the session rather than a field on the prompt.
    func switchModel(sessionID: String, model: OC2ModelRefInput) async throws {
        let body = try JSONCoding.encoder.encode(["model": model])
        try await http.send(builder.request(.post, "/api/session/\(sessionID)/model", body: body))
    }

    func switchAgent(sessionID: String, agent: String) async throws {
        let body = try JSONCoding.encoder.encode(["agent": agent])
        try await http.send(builder.request(.post, "/api/session/\(sessionID)/agent", body: body))
    }

    func command(sessionID: String, request: OC2CommandRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(
            builder.request(.post, "/api/session/\(sessionID)/command", body: body),
            timeout: ConnectionPolicy.blockingTurn)
    }

    func interrupt(sessionID: String) async throws {
        try await http.send(
            builder.request(.post, "/api/session/\(sessionID)/interrupt", body: Self.emptyBody))
    }

    /// Sets aside `messageID` and everything after it, putting back the files changed since.
    func stageRevert(sessionID: String, messageID: String) async throws -> OC2Revert {
        let body = try JSONCoding.encoder.encode(OC2RevertRequest(messageID: messageID))
        return try unwrap(
            await http.send(
                builder.request(.post, "/api/session/\(sessionID)/revert/stage", body: body)))
    }

    func clearRevert(sessionID: String) async throws {
        try await http.send(builder.request(.delete, "/api/session/\(sessionID)/revert"))
    }

    func inbox(sessionID: String) async throws -> [OC2InboxItem] {
        try unwrap(await http.send(builder.request(.get, "/api/session/\(sessionID)/inbox")))
    }

    func synthetic(sessionID: String, request: OC2SyntheticRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(
            builder.request(.post, "/api/session/\(sessionID)/synthetic", body: body))
    }

    /// Admits a compaction to the session's inbox and returns at once; the stream reports the
    /// start, the summary and the seam.
    func compact(sessionID: String) async throws {
        try await http.send(
            builder.request(.post, "/api/session/\(sessionID)/compact", body: Self.emptyBody))
    }

    func pendingPermissions(sessionID: String) async throws -> [OC2Permission] {
        try unwrap(await http.send(builder.request(.get, "/api/session/\(sessionID)/permission")))
    }

    func replyPermission(sessionID: String, requestID: String, decision: String) async throws {
        let body = try JSONCoding.encoder.encode(["decision": decision])
        try await http.send(
            builder.request(
                .post, "/api/session/\(sessionID)/permission/\(requestID)/reply", body: body))
    }

    func pendingForms(sessionID: String) async throws -> [OC2Form] {
        try unwrap(await http.send(builder.request(.get, "/api/session/\(sessionID)/form")))
    }

    func replyForm(sessionID: String, formID: String, answer: JSONValue) async throws {
        let body = try JSONCoding.encoder.encode(["answer": answer])
        try await http.send(
            builder.request(.post, "/api/session/\(sessionID)/form/\(formID)/reply", body: body))
    }

    func cancelForm(sessionID: String, formID: String) async throws {
        try await http.send(
            builder.request(.delete, "/api/session/\(sessionID)/form/\(formID)"))
    }

    func diff(sessionID: String) async throws -> [OC2Diff] {
        try unwrap(await http.send(builder.request(.get, "/api/session/\(sessionID)/diff")))
    }

    func files(path: String, directory: String?) async throws -> [OC2FSEntry] {
        try unwrap(
            await http.send(
                builder.request(
                    .get, "/api/fs/list",
                    query: Self.locationQuery(directory) + [URLQueryItem(name: "path", value: path)]
                )))
    }

    func fileBytes(path: String, directory: String?) async throws -> Data {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return try await http.send(
            builder.request(.get, "/api/fs/read/\(trimmed)", query: Self.locationQuery(directory)))
    }

    func find(query: String, directory: String?) async throws -> [OC2FSEntry] {
        try unwrap(
            await http.send(
                builder.request(
                    .get, "/api/fs/find",
                    query: Self.locationQuery(directory) + [
                        URLQueryItem(name: "query", value: query),
                        URLQueryItem(name: "type", value: "file"),
                    ])))
    }

    func models() async throws -> [OC2Model] {
        try unwrap(await http.send(builder.request(.get, "/api/model")))
    }

    func defaultModel() async throws -> OC2Model? {
        try unwrap(await http.send(builder.request(.get, "/api/model/default")))
    }

    func providers() async throws -> [OC2Provider] {
        try unwrap(await http.send(builder.request(.get, "/api/provider")))
    }

    func agents() async throws -> [OC2Agent] {
        try unwrap(await http.send(builder.request(.get, "/api/agent")))
    }

    func commands(directory: String?) async throws -> [OC2Command] {
        try unwrap(
            await http.send(
                builder.request(.get, "/api/command", query: Self.locationQuery(directory))))
    }

    /// Runs one command on the server's own machine, in a pty the server owns, and answers with
    /// the pty's id. The pty outlives the command — a process that exited is still listed — which
    /// is what lets a caller tell a command that ran from a server that is no longer there.
    func spawn(command: String, args: [String]) async throws -> String {
        let body = try JSONCoding.encoder.encode(OC2PtyRequest(command: command, args: args))
        let pty: OC2Pty = try unwrap(await http.send(builder.request(.post, "/api/pty", body: body)))
        return pty.id
    }

    func ptyIDs() async throws -> [String] {
        let ptys: [OC2Pty] = try unwrap(await http.send(builder.request(.get, "/api/pty")))
        return ptys.map(\.id)
    }

    /// Every workspace's events on one connection; each frame names the session it belongs to.
    func eventStream() -> AsyncThrowingStream<SSEvent, Error> {
        do {
            return http.serverSentEvents(try builder.eventStreamRequest("/api/event"))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
