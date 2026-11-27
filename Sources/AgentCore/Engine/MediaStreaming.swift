import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Which players a stream has to suit. AVFoundation reads MP4, QuickTime and the usual audio
/// containers and nothing else, so an Apple client asks for `apple` and a bridge with ffmpeg hands
/// back a copy it can play; mpv plays anything, so Linux asks for `any`.
public enum MediaPlayback: String, Sendable, Codable {
    case any
    case apple
}

/// A stream a server handed a player: where to open it, and what it is, which for a converted
/// file is the copy's type rather than the original's.
public struct MediaStream: Sendable, Equatable {
    public let url: URL
    public let mime: String?
    public let size: Int?

    public init(url: URL, mime: String?, size: Int?) {
        self.url = url
        self.mime = mime
        self.size = size
    }
}

/// A server that can hand a player a URL of its own for a file on its machine.
///
/// A video or a song is read by a player, not by this kit: AVPlayer and mpv ask for byte ranges as
/// they go and know nothing of the credentials a backend sends. A bridge answers with a ticket, a
/// URL that admits reads of that one file for a while without the password, so any player can
/// open it and seek in it. A server that cannot (an older bridge) answers nil, and the client
/// falls back to fetching the whole file.
public protocol MediaStreamingBackend: CodingAgentBackend {
    /// A stream for the file that players of `playback` can open, nil when this server hands out
    /// none. Throws when the server can, but the file is not there, cannot be read or cannot be
    /// made playable there.
    func mediaStream(for file: FileReference, playback: MediaPlayback) async throws -> MediaStream?
}

extension MediaStreamingBackend {
    /// A URL any player can open for the file as it is, nil when this server hands out none.
    public func streamingURL(for file: FileReference) async throws -> URL? {
        try await mediaStream(for: file, playback: .any)?.url
    }
}

/// A server that can put a whole file on this device's disk without holding it in memory, for a
/// player that cannot stream from it.
public protocol MediaDownloadingBackend: CodingAgentBackend {
    func download(_ file: FileReference, to destination: URL) async throws
}

extension CodingAgentBackend {
    /// The file on this device's disk at `destination`: streamed there by a server that can, read
    /// whole and written by any other.
    public func fetchFile(_ file: FileReference, to destination: URL) async throws {
        if let downloading = self as? any MediaDownloadingBackend {
            try await downloading.download(file, to: destination)
            return
        }
        let data = try await attachmentData(file)
        try data.write(to: destination, options: .atomic)
    }
}

/// Streams a request's body to a file, a chunk at a time as it arrives, so a film never sits in
/// memory. The bytes go to a sibling of the destination that is moved into place only once the
/// whole body is there, so a broken transfer never leaves half a file under the real name.
public enum FileDownload {
    public static func perform(
        _ request: URLRequest, to destination: URL,
        configuration: URLSessionConfiguration = FileDownload.configuration
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
            let handle = FileHandle(forWritingAtPath: partial.path)
        else { throw AgentError.connection("cannot write \(partial.path)") }
        let writer = Writer(handle: handle)
        let session = URLSession(configuration: configuration, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.begin(continuation)
                session.dataTask(with: request).resume()
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// No response cache: a film written to disk must not be kept a second time in URLCache.
    public static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private final class Writer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var status = 0
        private var failure: (any Error)?
        private var continuation: CheckedContinuation<Void, any Error>?

        init(handle: FileHandle) {
            self.handle = handle
        }

        func begin(_ continuation: CheckedContinuation<Void, any Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            lock.withLock { status = code }
            completionHandler((200..<300).contains(code) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock {
                guard failure == nil else { return }
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    failure = error
                    dataTask.cancel()
                }
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            let (continuation, status, failure) = lock.withLock {
                let taken = self.continuation
                self.continuation = nil
                return (taken, self.status, self.failure)
            }
            try? handle.close()
            if let failure {
                continuation?.resume(throwing: failure)
            } else if !(200..<300).contains(status) {
                continuation?.resume(throwing: AgentError.http(status: status, body: ""))
            } else if let error {
                continuation?.resume(throwing: AgentError.connection(error.localizedDescription))
            } else {
                continuation?.resume()
            }
        }
    }
}
