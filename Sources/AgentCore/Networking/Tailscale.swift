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

    public var lastSeenDate: Date? {
        lastSeen.flatMap { try? Date($0, strategy: .iso8601) }
    }

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

        public var dedupeKey: String { "\(recommendedProfileName)|\(backend.rawValue)" }
    }

    public typealias ProbeFunction = @Sendable (URL, ConnectionPolicy) async -> ConnectionProbe.Outcome

    private let probeFn: ProbeFunction
    private let logger = AgentLog.logger("scanner")
    private let maxConcurrentProbes = 16

    public init() {
        let probe = ConnectionProbe()
        self.probeFn = { url, policy in
            await probe.probe(
                baseURL: url, credentials: nil, policy: policy, retryUnreachable: false)
        }
    }

    init(probeFn: @escaping ProbeFunction) {
        self.probeFn = probeFn
    }

    /// Devices that could plausibly host an agent server: seen online
    /// recently and running a general-purpose OS. Offline peers blackhole
    /// every probe into a full timeout, which is what makes naive scans
    /// take minutes; phones and TVs can never run a server at all.
    public static func scannableDevices(
        _ devices: [TailscaleDevice], now: Date = Date()
    ) -> [TailscaleDevice] {
        let excludedOS: Set<String> = ["ios", "ipados", "tvos", "watchos", "android"]
        let cutoff = now.addingTimeInterval(-600)
        return devices
            .filter { device in
                if let os = device.os?.lowercased(), excludedOS.contains(os) { return false }
                guard let seen = device.lastSeenDate else { return true }
                return seen > cutoff
            }
            .sorted { ($0.lastSeenDate ?? .distantFuture) > ($1.lastSeenDate ?? .distantFuture) }
    }

    /// True when `a` should represent a logical server over `b`: reachable
    /// without auth beats password-gated, and a MagicDNS name beats a raw IP.
    public static func preferred(_ a: Suggestion, over b: Suggestion) -> Bool {
        if a.requiresAuth != b.requiresAuth { return !a.requiresAuth }
        let aNamed = !isIPLiteral(a.baseURL.host ?? "")
        let bNamed = !isIPLiteral(b.baseURL.host ?? "")
        if aNamed != bNamed { return aNamed }
        return false
    }

    /// Whether `host` is a raw IP address rather than a MagicDNS name. An IPv6
    /// literal always contains a colon — its hex groups (e.g. `fd7a:115c::53`)
    /// carry letters `a`–`f` that are not decimal digits, so a digits-only test
    /// would misread it as a name; an IPv4 literal is only digits and dots.
    /// Everything else counts as a name.
    private static func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Probes every candidate host/port of the scannable devices. Findings
    /// stream through `onFound` as they land (deduplication is the caller's
    /// concern mid-scan — see `Suggestion.dedupeKey` and `preferred`);
    /// the returned array is the final deduplicated result.
    public func scan(
        devices: [TailscaleDevice],
        ports: [Int] = [4096, 4098],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onFound: (@Sendable (Suggestion) -> Void)? = nil
    ) async -> [Suggestion] {
        let started = Date()
        let policy = ConnectionPolicy(requestTimeout: .seconds(3), resourceTimeout: .seconds(5))
        var targets: [(device: TailscaleDevice, host: String, port: Int, url: URL)] = []
        for device in Self.scannableDevices(devices) {
            for port in ports {
                for host in candidateHosts(for: device) {
                    guard let url = URL(string: "http://\(bracketed(host)):\(port)") else { continue }
                    targets.append((device, host, port, url))
                }
            }
        }
        var results: [(order: Int, suggestion: Suggestion)] = []
        var summary: [String: Int] = [:]
        var checked = 0
        await withTaskGroup(of: (Int, Suggestion?, String).self) { group in
            var iterator = targets.enumerated().makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let (order, target) = iterator.next() else { return false }
                group.addTask {
                    let outcome = await self.probeFn(target.url, policy)
                    self.logger.debug(
                        "probe \(target.url.absoluteString): \(String(describing: outcome))")
                    return (order, self.suggestion(for: target, outcome: outcome), Self.kind(of: outcome))
                }
                return true
            }
            var launched = 0
            while launched < maxConcurrentProbes, addNext() { launched += 1 }
            for await (order, suggestion, kind) in group {
                if let suggestion {
                    results.append((order, suggestion))
                    onFound?(suggestion)
                }
                checked += 1
                summary[kind, default: 0] += 1
                onProgress?(checked, targets.count)
                _ = addNext()
            }
        }
        logger.info(
            "scan finished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(summary)")
        return dedupe(results)
    }

    /// Prefers a hostname-addressed, non-auth suggestion for each logical
    /// server, and orders deterministically by the original device/port order.
    private func dedupe(_ results: [(order: Int, suggestion: Suggestion)]) -> [Suggestion] {
        let ranked = results.sorted { a, b in
            if Self.preferred(a.suggestion, over: b.suggestion) { return true }
            if Self.preferred(b.suggestion, over: a.suggestion) { return false }
            return a.order < b.order
        }
        var seen: Set<String> = []
        return ranked.compactMap { entry in
            guard seen.insert(entry.suggestion.dedupeKey).inserted else { return nil }
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

    /// One probe per address family is waste: the Tailscale IPv6 address
    /// reaches the same node as the IPv4 one, so probe IPv4 plus the MagicDNS
    /// name (which ranks higher for the saved profile), falling back to
    /// whatever addresses exist on a v6-only tailnet.
    private func candidateHosts(for device: TailscaleDevice) -> [String] {
        var hosts: [String] = []
        let v4 = device.addresses.filter { !$0.contains(":") }
        hosts.append(contentsOf: v4.isEmpty ? device.addresses : v4)
        if let name = device.name, !name.isEmpty { hosts.append(name) }
        return hosts
    }
}
