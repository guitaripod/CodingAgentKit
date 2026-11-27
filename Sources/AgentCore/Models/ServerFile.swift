import Foundation

/// A file on the machine a conversation runs on, known only by the path an agent wrote.
///
/// A picture a tool handed back arrives with a URL its server made for it. A file the agent only
/// names has none, so it is carried under the route the bridges serve any readable file at,
/// `/files/raw?path=`, and every backend reads a reference under that route as "this path on my
/// machine" and fetches it the way its own server can. The revision rides along so the same path
/// named again after the file changed is a different URL, and a client that caches by URL fetches
/// the new file rather than showing the one it already holds.
public enum ServerFile {
    public static let route = "/files/raw"

    public static func reference(path: String, mime: String?, revision: String?) -> FileReference {
        var url = "\(route)?path=\(encoded(path))"
        if let revision, !revision.isEmpty { url += "&rev=\(encoded(revision))" }
        return FileReference(path: path, mime: mime, url: url, filename: basename(path))
    }

    /// The path a reference under `route` names, or nil for any other reference.
    public static func path(of file: FileReference) -> String? {
        guard let url = file.url, url.hasPrefix(route + "?"),
            let components = URLComponents(string: url),
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
            !path.isEmpty
        else { return nil }
        return path
    }

    /// The last component of a path, read without Foundation's path APIs, which trap on Linux for
    /// some relative paths.
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
