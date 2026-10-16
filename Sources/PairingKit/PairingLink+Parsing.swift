import Foundation

extension PairingLink {
    private static let maxLinkLength = 2048
    private static let prefix = "\(scheme)://\(action)?"

    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    /// Strict: only `tailscode://connect?…` with no userinfo, port, path or fragment, and no
    /// parameter twice. Unknown parameters are ignored so a newer link still reads.
    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maxLinkLength, text.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
            text.lowercased().hasPrefix(Self.prefix), !text.contains("#"),
            let parameters = Self.parameters(String(text.dropFirst(Self.prefix.count))),
            Self.acceptsVersion(parameters["v"]),
            let host = parameters["host"], let portText = parameters["port"],
            let port = Self.port(portText),
            let agentText = parameters["agent"], let agent = PairingAgent(rawValue: agentText)
        else { return nil }
        self.init(host: host, port: port, agent: agent, name: parameters["name"], key: parameters["key"])
    }

    private static func parameters(_ query: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let key = String(pair[..<separator])
            guard !key.isEmpty, result[key] == nil,
                let value = PairingEncoding.decode(pair[pair.index(after: separator)...])
            else { return nil }
            result[key] = value
        }
        return result
    }

    private static func acceptsVersion(_ text: String?) -> Bool {
        guard let text else { return true }
        guard let number = digits(text, maxCount: 9) else { return false }
        return number >= 1
    }

    private static func port(_ text: String) -> Int? {
        digits(text, maxCount: 5)
    }

    private static func digits(_ text: String, maxCount: Int) -> Int? {
        guard (1...maxCount).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return Int(text)
    }
}
