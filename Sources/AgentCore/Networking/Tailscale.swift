import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct TailscaleOAuthCredentials: Sendable, Codable, Hashable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct TailscaleDevice: Sendable, Hashable, Codable {
    public var id: String?
    public var nodeId: String?
    public var name: String?
    public var hostname: String
    public var addresses: [String]
    public var os: String?
    public var user: String?
    public var authorized: Bool?
    public var lastSeen: String?

    public init(
        id: String? = nil,
        nodeId: String? = nil,
        name: String?,
        hostname: String,
        addresses: [String],
        os: String? = nil,
        user: String? = nil,
        authorized: Bool? = nil,
        lastSeen: String? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.name = name
        self.hostname = hostname
        self.addresses = addresses
        self.os = os
        self.user = user
        self.authorized = authorized
        self.lastSeen = lastSeen
    }
}

public struct TailscaleClient: Sendable {
    private let http: HTTPClient

    public init(policy: ConnectionPolicy = .default) {
        self.http = HTTPClient(policy: policy, logger: AgentLog.logger("tailscale"))
    }

    public func fetchDevices(credentials: TailscaleOAuthCredentials) async throws -> [TailscaleDevice] {
        let token = try await exchangeToken(credentials: credentials)
        return try await fetchDevices(with: token)
    }

    /// Fetch using a raw API access token (tskey-api-...) or OAuth access token.
    public func fetchDevices(with token: String) async throws -> [TailscaleDevice] {
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await http.send(req)
        struct DevicesResponse: Decodable {
            struct Device: Decodable {
                let id: String?
                let nodeId: String?
                let name: String?
                let hostname: String
                let addresses: [String]
                let os: String?
                let user: String?
                let authorized: Bool?
                let lastSeen: String?
            }
            let devices: [Device]
        }
        let resp = try JSONCoding.decoder.decode(DevicesResponse.self, from: data)
        return resp.devices.map { d in
            TailscaleDevice(
                id: d.id,
                nodeId: d.nodeId,
                name: d.name,
                hostname: d.hostname,
                addresses: d.addresses,
                os: d.os,
                user: d.user,
                authorized: d.authorized,
                lastSeen: d.lastSeen
            )
        }
    }

    private func exchangeToken(credentials: TailscaleOAuthCredentials) async throws -> String {
        let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let cid = Self.formEncoded(credentials.clientID)
        let csec = Self.formEncoded(credentials.clientSecret)
        req.httpBody = "client_id=\(cid)&client_secret=\(csec)".data(using: .utf8)
        let data = try await http.send(req)
        struct TokenResponse: Decodable {
            let access_token: String
        }
        let tok = try JSONCoding.decoder.decode(TokenResponse.self, from: data)
        return tok.access_token
    }

    /// Percent-encodes for an `application/x-www-form-urlencoded` body, where
    /// `.urlQueryAllowed` is wrong: it passes `+`, `&`, and `=` through, which
    /// the server decodes as space / separator characters.
    private static func formEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

public struct TailnetScanner: Sendable {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let baseURL: URL
        public let backend: AgentType
        public let version: String?
        public let requiresAuth: Bool
        public let recommendedProfileName: String
        public let os: String?
        public let lastSeen: String?
    }

    private let probe = ConnectionProbe()
    private let logger = AgentLog.logger("scanner")
    private let maxConcurrentProbes = 16

    public init() {}

    public func scan(devices: [TailscaleDevice], ports: [Int] = [4096, 4098]) async -> [Suggestion] {
        let policy = ConnectionPolicy(requestTimeout: .seconds(10), resourceTimeout: .seconds(15))
        var targets: [(device: TailscaleDevice, host: String, port: Int, url: URL)] = []
        for device in devices {
            for port in ports {
                for host in candidateHosts(for: device) {
                    guard let url = URL(string: "http://\(bracketed(host)):\(port)") else { continue }
                    targets.append((device, host, port, url))
                }
            }
        }
        var results: [(order: Int, suggestion: Suggestion)] = []
        var summary: [String: Int] = [:]
        await withTaskGroup(of: (Int, Suggestion?, String).self) { group in
            var iterator = targets.enumerated().makeIterator()
            func addNext() -> Bool {
                guard let (order, target) = iterator.next() else { return false }
                group.addTask {
                    let outcome = await self.probe.probe(
                        baseURL: target.url, credentials: nil, policy: policy)
                    self.logger.debug(
                        "probe \(target.url.absoluteString): \(String(describing: outcome))")
                    return (order, self.suggestion(for: target, outcome: outcome), Self.kind(of: outcome))
                }
                return true
            }
            var launched = 0
            while launched < maxConcurrentProbes, addNext() { launched += 1 }
            for await (order, suggestion, kind) in group {
                if let suggestion { results.append((order, suggestion)) }
                summary[kind, default: 0] += 1
                _ = addNext()
            }
        }
        logger.info("scan summary: \(summary)")
        return dedupe(results)
    }

    /// Prefers a hostname-addressed, non-auth suggestion for each logical
    /// server, and orders deterministically by the original device/port order.
    private func dedupe(_ results: [(order: Int, suggestion: Suggestion)]) -> [Suggestion] {
        let ranked = results.sorted { a, b in
            let sa = a.suggestion
            let sb = b.suggestion
            if sa.requiresAuth != sb.requiresAuth { return !sa.requiresAuth }
            let aIsName = !(sa.baseURL.host ?? "").allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
            let bIsName = !(sb.baseURL.host ?? "").allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
            if aIsName != bIsName { return aIsName }
            return a.order < b.order
        }
        var seen: Set<String> = []
        return ranked.compactMap { entry in
            let key = "\(entry.suggestion.recommendedProfileName)|\(entry.suggestion.backend.rawValue)"
            guard seen.insert(key).inserted else { return nil }
            return entry.suggestion
        }
    }

    private func suggestion(
        for target: (device: TailscaleDevice, host: String, port: Int, url: URL),
        outcome: ConnectionProbe.Outcome
    ) -> Suggestion? {
        let device = target.device
        let label = device.hostname.isEmpty ? (device.name ?? target.host) : device.hostname
        switch outcome {
        case .ok(let agentType, let version):
            return Suggestion(
                id: "\(target.host):\(target.port)",
                name: "\(label) · \(agentType.displayName)",
                baseURL: target.url,
                backend: agentType,
                version: version,
                requiresAuth: false,
                recommendedProfileName: label,
                os: device.os,
                lastSeen: device.lastSeen)
        case .authFailed:
            let guessed: AgentType = target.port == 4096 ? .openCode : .claudeCode
            return Suggestion(
                id: "\(target.host):\(target.port)",
                name: "\(label) (password required)",
                baseURL: target.url,
                backend: guessed,
                version: nil,
                requiresAuth: true,
                recommendedProfileName: label,
                os: device.os,
                lastSeen: device.lastSeen)
        case .unreachable, .notAnAgentServer:
            return nil
        }
    }

    private static func kind(of outcome: ConnectionProbe.Outcome) -> String {
        switch outcome {
        case .ok: return "ok"
        case .authFailed: return "authFailed"
        case .unreachable: return "unreachable"
        case .notAnAgentServer: return "notAgent"
        }
    }

    private func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private func candidateHosts(for device: TailscaleDevice) -> [String] {
        var h: [String] = []
        h.append(contentsOf: device.addresses)
        if let n = device.name, !n.isEmpty { h.append(n) }
        return h
    }
}
