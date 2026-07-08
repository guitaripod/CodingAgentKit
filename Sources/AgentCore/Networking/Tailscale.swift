import Foundation

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
        let cid = credentials.clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let csec = credentials.clientSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        req.httpBody = "client_id=\(cid)&client_secret=\(csec)".data(using: .utf8)
        let data = try await http.send(req)
        struct TokenResponse: Decodable {
            let access_token: String
        }
        let tok = try JSONCoding.decoder.decode(TokenResponse.self, from: data)
        return tok.access_token
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

    public init() {}

    public func scan(devices: [TailscaleDevice], ports: [Int] = [4096, 4098]) async -> [Suggestion] {
        let policy = ConnectionPolicy(requestTimeout: .seconds(10), resourceTimeout: .seconds(15))
        var results: [Suggestion] = []
        var okCount = 0
        var authCount = 0
        var unreachableCount = 0
        var notAgentCount = 0
        await withTaskGroup(of: (Suggestion?, String).self) { group in
            for device in devices {
                let hosts = candidateHosts(for: device)
                for port in ports {
                    for host in hosts {
                        guard let url = URL(string: "http://\(host):\(port)") else { continue }
                        group.addTask {
                            let outcome = await self.probe.probe(baseURL: url, credentials: nil, policy: policy)
                            // Debug logging to diagnose why no servers are found (visible in idevicesyslog)
                            NSLog("[SCAN PROBE] host=%@ port=%d url=%@ outcome=%@", host, port, url.absoluteString, String(describing: outcome))
                            switch outcome {
                            case .ok(let agentType, let version):
                                let label = device.hostname.isEmpty ? (device.name ?? host) : device.hostname
                                let profName = device.hostname.isEmpty ? label : device.hostname
                                return (Suggestion(
                                    id: "\(host):\(port)",
                                    name: "\(label) · \(agentType.displayName)",
                                    baseURL: url,
                                    backend: agentType,
                                    version: version,
                                    requiresAuth: false,
                                    recommendedProfileName: profName,
                                    os: device.os,
                                    lastSeen: device.lastSeen
                                ), "ok")
                            case .authFailed:
                                let label = device.hostname.isEmpty ? (device.name ?? host) : device.hostname
                                let profName = device.hostname.isEmpty ? label : device.hostname
                                let guessed: AgentType = port == 4096 ? .openCode : .claudeCode
                                return (Suggestion(
                                    id: "\(host):\(port)",
                                    name: "\(label) (password required)",
                                    baseURL: url,
                                    backend: guessed,
                                    version: nil,
                                    requiresAuth: true,
                                    recommendedProfileName: profName,
                                    os: device.os,
                                    lastSeen: device.lastSeen
                                ), "auth")
                            case .unreachable:
                                return (nil, "unreachable")
                            case .notAnAgentServer:
                                return (nil, "notAgent")
                            }
                        }
                    }
                }
            }
            for await (s, type) in group {
                if let s { results.append(s) }
                switch type {
                case "ok": okCount += 1
                case "auth": authCount += 1
                case "unreachable": unreachableCount += 1
                case "notAgent": notAgentCount += 1
                default: break
                }
            }
        }
        NSLog("[TailnetScanner] summary: ok=%d authFailed=%d unreachable=%d notAgent=%d", okCount, authCount, unreachableCount, notAgentCount)
        // Deduplicate by logical server (hostname + backend) to avoid showing the same server
        // multiple times from different hostnames/IPs/ports.
        var seenServers: Set<String> = []
        return results.compactMap { $0 }.filter { s in
            let key = "\(s.recommendedProfileName)|\(s.backend.rawValue)"
            if seenServers.contains(key) { return false }
            seenServers.insert(key)
            return true
        }
    }

    private func candidateHosts(for device: TailscaleDevice) -> [String] {
        var h: [String] = []
        h.append(contentsOf: device.addresses)
        if let n = device.name, !n.isEmpty { h.append(n) }
        return h
    }
}
