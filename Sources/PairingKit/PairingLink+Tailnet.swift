extension PairingLink {
    public var isTailnetAddress: Bool { Self.isTailnetAddress(host) }

    /// Heuristic for "this host is on a tailnet": the 100.64.0.0/10 carrier-grade range Tailscale
    /// hands out, its `fd7a:115c:a1e0::/48` IPv6 range, or a `*.ts.net` MagicDNS name. A short
    /// MagicDNS name or a custom domain looks like any other host and is not recognized.
    public static func isTailnetAddress(_ host: String) -> Bool {
        guard let host = PairingHost.normalized(host) else { return false }
        if let octets = PairingHost.ipv4(host) {
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        if let groups = PairingHost.ipv6(host) {
            return groups[0] == 0xFD7A && groups[1] == 0x115C && groups[2] == 0xA1E0
        }
        return host.hasSuffix(".ts.net") && host.count > ".ts.net".count
    }
}
