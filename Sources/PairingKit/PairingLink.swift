import Foundation

/// The `tailscode://connect` link an agent bridge prints and the apps open. It only ever prefills a
/// setup screen: nothing is saved until the person confirms.
public struct PairingLink: Sendable, Hashable {
    public static let scheme = "tailscode"
    public static let action = "connect"
    public static let version = 1
    public static let maxNameLength = 64
    public static let maxKeyLength = 200

    /// A DNS name, MagicDNS name or IP literal, lowercased and without IPv6 brackets.
    public let host: String
    public let port: Int
    public let agent: PairingAgent
    public let name: String?
    public let key: String?

    /// `nil` when the host, port or key breaks the format. The name is cleaned and cut to 64
    /// characters rather than rejected, since it is only ever shown.
    public init?(host: String, port: Int, agent: PairingAgent, name: String? = nil, key: String? = nil) {
        guard let host = PairingHost.normalized(host), (1...65535).contains(port) else { return nil }
        if let key, key.count > Self.maxKeyLength { return nil }
        self.host = host
        self.port = port
        self.agent = agent
        self.name = name.flatMap(Self.cleanName)
        self.key = key?.isEmpty == false ? key : nil
    }

    /// The host as it goes into a URL authority: IPv6 literals in brackets.
    public var bracketedHost: String { host.contains(":") ? "[\(host)]" : host }

    public var url: URL {
        var items = [
            ("v", String(Self.version)), ("host", host), ("port", String(port)), ("agent", agent.rawValue),
        ]
        if let name { items.append(("name", name)) }
        if let key { items.append(("key", key)) }
        let query = items.map { "\($0.0)=\(PairingEncoding.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(Self.scheme)://\(Self.action)?\(query)")!
    }

    public var redacted: String {
        var parts = ["host: \(host)", "port: \(port)", "agent: \(agent.rawValue)"]
        if let name { parts.append("name: \(name)") }
        if key != nil { parts.append("key: <redacted>") }
        return "PairingLink(\(parts.joined(separator: ", ")))"
    }

    static func cleanName(_ raw: String) -> String? {
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !PairingEncoding.isStripped($0) }))
        let cut = String(kept.prefix(maxNameLength))
        return cut.isEmpty ? nil : cut
    }
}

extension PairingLink: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { redacted }
    public var debugDescription: String { redacted }
}
