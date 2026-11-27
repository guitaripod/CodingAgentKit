import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A bridge hands a player a ticket for one file: `POST /files/ticket` answers with a
/// `/files/raw?ticket=` URL its door admits without the password, for that file only and for a
/// while, with byte ranges, which is what AVPlayer and mpv need to start a long video at once and
/// seek in it. A bridge from before tickets has no such route and answers 404 with an empty body;
/// a bridge that has it says why it refused in JSON.
///
/// A player that reads only some formats asks for one it can: a bridge with ffmpeg converts the
/// file once into a copy it keeps, and says so in the answer's type. A bridge from before
/// conversion ignores the ask and answers with the file as it is, which the caller reads from the
/// type it was given.
extension ClaudeCodeBackend: MediaStreamingBackend {
    public func mediaStream(for file: FileReference, playback: MediaPlayback) async throws
        -> MediaStream?
    {
        guard let path = ServerFile.path(of: file) ?? file.path else { return nil }
        let body = try BridgeCoding.encoder.encode(
            BRFileTicketRequest(path: path, playable: playback == .any ? nil : playback.rawValue))
        let data: Data
        do {
            data = try await http.send(
                builder.request(.post, "/files/ticket", body: body), timeout: .seconds(600))
        } catch AgentError.http(let status, let body) where Self.predatesTickets(status, body) {
            return nil
        }
        let ticket = try BridgeCoding.decoder.decode(BRFileTicket.self, from: data)
        guard let components = URLComponents(string: ticket.url), components.path.hasPrefix("/")
        else { return nil }
        let url = try builder.url(path: components.path, query: components.queryItems ?? [])
        return MediaStream(url: url, mime: ticket.mime, size: ticket.size)
    }

    /// Whether a refusal is the bridge not knowing the route at all, rather than knowing it and
    /// saying the file cannot be had.
    static func predatesTickets(_ status: Int, _ body: String) -> Bool {
        guard status == 404 || status == 405 else { return false }
        return !body.contains("\"error\"")
    }
}

struct BRFileTicketRequest: Encodable {
    let path: String
    let playable: String?
}

struct BRFileTicket: Decodable {
    let url: String
    let size: Int?
    let mime: String?
}
