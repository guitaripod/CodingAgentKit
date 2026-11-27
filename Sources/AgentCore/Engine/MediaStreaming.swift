import Foundation

/// A server that can hand a player a URL of its own for a file on its machine.
///
/// A video or a song is read by a player, not by this kit: AVPlayer and mpv ask for byte ranges as
/// they go and know nothing of the credentials a backend sends. A bridge answers with a ticket, a
/// URL that admits reads of that one file for a while without the password, so any player can
/// open it and seek in it. A server that cannot (an older bridge) answers nil, and the client
/// falls back to fetching the whole file through `attachmentData`.
public protocol MediaStreamingBackend: CodingAgentBackend {
    /// A URL any player can open for the file, nil when this server cannot hand one out. Throws
    /// when the server can, but the file is not there or cannot be read.
    func streamingURL(for file: FileReference) async throws -> URL?
}
