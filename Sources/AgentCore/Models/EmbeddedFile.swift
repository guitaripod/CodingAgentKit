import Foundation

/// A file whose bytes arrived inside the conversation itself. opencode hands a picture a tool read
/// back as a `data:` URL in the part that names it, so a transcript with a dozen screenshots held
/// twenty megabytes of base64 as strings for as long as the chat was open, in every copy of every
/// message: a Mac with five such chats open carried 175 MB of them. The bytes are put on a shelf
/// on disk as the conversation is read and the part keeps a short reference, which a backend reads
/// back when somebody looks at the picture.
public final class EmbeddedFileShelf: @unchecked Sendable {
    public static let shared = EmbeddedFileShelf(directory: defaultDirectory)

    /// What a shelved file's reference begins with. Read by every cached transcript, so it is
    /// added to and never renamed.
    public static let scheme = "embedded:"

    /// A `data:` URL shorter than this stays where it is: a reference would save nothing.
    static let smallest = 2048

    private let directory: URL
    private let lock = NSLock()
    private var known: Set<String> = []
    private var prepared = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// Whether `url` is a reference to a shelved file.
    public static func isShelved(_ url: String) -> Bool {
        url.hasPrefix(scheme)
    }

    /// The reference that stands for a `data:` URL once its bytes are on the shelf. Anything that
    /// is not a `data:` URL worth shelving, and any URL the disk refused, comes back as it was.
    public func shelved(_ url: String?) -> String? {
        guard let url, url.utf8.count >= Self.smallest, url.hasPrefix("data:") else { return url }
        let name = Self.name(for: url)
        let reference = Self.scheme + name
        lock.lock()
        defer { lock.unlock() }
        if known.contains(name) { return reference }
        prepare()
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            known.insert(name)
            return reference
        }
        guard let bytes = Self.dataURLBytes(url), (try? bytes.write(to: file, options: .atomic)) != nil
        else { return url }
        known.insert(name)
        return reference
    }

    /// A file reference with its `data:` URL shelved, and the type the URL named kept where the
    /// reference had none.
    public func shelved(_ file: FileReference) -> FileReference {
        guard let url = file.url, url.hasPrefix("data:") else { return file }
        var kept = file
        kept.url = shelved(url)
        if kept.mime == nil { kept.mime = Self.mime(ofDataURL: url) }
        return kept
    }

    /// The bytes a reference stands for, or nil when it is not a reference or its file is gone.
    public func bytes(of url: String) -> Data? {
        guard Self.isShelved(url) else { return nil }
        let name = String(url.dropFirst(Self.scheme.count))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The bytes a `data:` URL carries.
    public static func dataURLBytes(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.utf8.firstIndex(of: UInt8(ascii: ",")) else {
            return nil
        }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let payload = url[url.index(after: comma)...]
        guard header.hasSuffix(";base64") else {
            return Data((payload.removingPercentEncoding ?? String(payload)).utf8)
        }
        if let plain = Data(base64Encoded: String(payload)) { return plain }
        let cleaned = (payload.removingPercentEncoding ?? String(payload)).filter { !$0.isWhitespace }
        return Data(base64Encoded: cleaned)
    }

    /// The media type a `data:` URL names, or nil when it names none.
    static func mime(ofDataURL url: String) -> String? {
        guard let end = url.utf8.prefix(256).firstIndex(where: { $0 == UInt8(ascii: ";") || $0 == UInt8(ascii: ",") })
        else { return nil }
        let mime = url[url.index(url.startIndex, offsetBy: 5)..<end]
        return mime.isEmpty ? nil : String(mime)
    }

    /// A name that is the same for the same URL and, for all practical purposes, for no other:
    /// two 64-bit sums over every byte and the length.
    static func name(for url: String) -> String {
        var text = url
        let (first, second, count) = text.withUTF8 { bytes -> (UInt64, UInt64, Int) in
            var first: UInt64 = 0xcbf2_9ce4_8422_2325
            var second: UInt64 = 0x9e37_79b9_7f4a_7c15
            for byte in bytes {
                first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
                second = (second &+ UInt64(byte)) &* 0xff51_afd7_ed55_8ccd
                second ^= second >> 29
            }
            return (first, second, bytes.count)
        }
        return String(first, radix: 16) + "-" + String(second, radix: 16) + "-" + String(count, radix: 16)
    }

    /// Makes the shelf's folder and, once a process, clears what nothing has asked for in a month
    /// and then the oldest of what is left over the shelf's size. Called with the lock held.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async { [self] in tidy() }
    }

    static let keptFor: TimeInterval = 30 * 24 * 3600
    static let largest = 1 << 30

    func tidy(now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys))
        else { return }
        var held: [(file: URL, at: Date, size: Int)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: keys)
            let at = values?.contentModificationDate ?? now
            if now.timeIntervalSince(at) > Self.keptFor {
                remove(file)
            } else {
                held.append((file, at, values?.fileSize ?? 0))
            }
        }
        var total = held.reduce(0) { $0 + $1.size }
        for entry in held.sorted(by: { $0.at < $1.at }) where total > Self.largest {
            if remove(entry.file) { total -= entry.size }
        }
    }

    /// Removes a file nothing in this process has asked for.
    @discardableResult
    private func remove(_ file: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !known.contains(file.lastPathComponent) else { return false }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }

    private static var defaultDirectory: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("CodingAgentKit/embedded", isDirectory: true)
    }
}
