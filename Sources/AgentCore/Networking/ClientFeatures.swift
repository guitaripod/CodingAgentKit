import Foundation

/// What the app driving this kit can show, said to every server on every request
/// (`X-Client-Features`, comma-separated), so a server that writes for the reader can write for the
/// app in front of it: a bridge tells its agent that a bare path shows a picture only when the app
/// that started the conversation draws one. Declared once at launch; a server that does not read
/// the header is told nothing new.
public enum ClientFeatures {
    public static let header = "X-Client-Features"

    /// Names a client declares: features are added, never renamed.
    public static let mediaByPath = "media-by-path"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String] = []

    public static func declare(_ features: [String]) {
        lock.withLock { names = features }
    }

    public static var declared: [String] {
        lock.withLock { names }
    }

    static var headerValue: String? {
        let names = declared
        return names.isEmpty ? nil : names.joined(separator: ",")
    }
}
