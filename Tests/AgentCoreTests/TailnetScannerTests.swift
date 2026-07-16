import Foundation
import Testing

@testable import AgentCore

private func device(
    _ hostname: String, name: String? = nil, addresses: [String] = ["100.64.0.1"],
    os: String? = "linux", lastSeenAgo: TimeInterval? = 10, now: Date = Date()
) -> TailscaleDevice {
    TailscaleDevice(
        name: name ?? "\(hostname).tail.ts.net",
        hostname: hostname,
        addresses: addresses,
        os: os,
        lastSeen: lastSeenAgo.map {
            now.addingTimeInterval(-$0).ISO8601Format()
        })
}

@Suite struct TailnetScannerTests {
    @Test func scannableDevicesSkipsOfflineAndPhones() {
        let now = Date()
        let devices = [
            device("arch", os: "linux", lastSeenAgo: 30, now: now),
            device("g14", os: "linux", lastSeenAgo: 3600 * 24 * 100, now: now),
            device("iphone", os: "iOS", lastSeenAgo: 5, now: now),
            device("appletv", os: "tvOS", lastSeenAgo: 5, now: now),
            device("mystery", os: "linux", lastSeenAgo: nil, now: now),
            device("macbook", os: "macOS", lastSeenAgo: 120, now: now),
        ]
        let scannable = TailnetScanner.scannableDevices(devices, now: now)
        #expect(scannable.map(\.hostname) == ["mystery", "arch", "macbook"])
    }

    @Test func scanProbesOnlyV4AndNameAndStreams() async {
        let now = Date()
        let devices = [
            device(
                "arch", addresses: ["100.64.0.1", "fd7a:115c::1"], os: "linux",
                lastSeenAgo: 5, now: now),
            device("dead", os: "linux", lastSeenAgo: 3600 * 24, now: now),
        ]
        let probed = Locked<[String]>([])
        let streamed = Locked<[String]>([])
        let progress = Locked<[Int]>([])
        let scanner = TailnetScanner { url, _ in
            probed.mutate { $0.append(url.absoluteString) }
            if url.port == 4098 {
                return .ok(agentType: .claudeCode, version: "claude")
            }
            return .unreachable("refused")
        }
        let found = await scanner.scan(
            devices: devices,
            onProgress: { checked, _ in progress.mutate { $0.append(checked) } },
            onFound: { suggestion in streamed.mutate { $0.append(suggestion.id) } })

        let urls = probed.value
        #expect(urls.count == 4)
        #expect(!urls.contains { $0.contains("fd7a") })
        #expect(urls.contains { $0.contains("arch.tail.ts.net") })
        #expect(!urls.contains { $0.contains("dead") })

        #expect(found.count == 1)
        #expect(found.first?.backend == .claudeCode)
        #expect(streamed.value.count == 2)
        #expect(progress.value.sorted() == [1, 2, 3, 4])
    }

    @Test func dedupePrefersUnauthenticatedNamedHosts() async {
        let devices = [
            device("arch", addresses: ["100.64.0.1"], os: "linux", lastSeenAgo: 5)
        ]
        let scanner = TailnetScanner { url, _ in
            guard url.port == 4098 else { return .unreachable("refused") }
            let isName = url.host?.contains("tail.ts.net") == true
            return isName ? .ok(agentType: .claudeCode, version: nil) : .authFailed
        }
        let found = await scanner.scan(devices: devices)
        #expect(found.count == 1)
        #expect(found.first?.requiresAuth == false)
        #expect(found.first?.baseURL.host == "arch.tail.ts.net")
    }

    @Test func preferredRanking() {
        func suggestion(_ host: String, auth: Bool) -> TailnetScanner.Suggestion {
            TailnetScanner.Suggestion(
                id: host, name: host, baseURL: URL(string: "http://\(host):4098")!,
                backend: .claudeCode, version: nil, requiresAuth: auth,
                recommendedProfileName: "arch", os: nil, lastSeen: nil)
        }
        let open = suggestion("arch.tail.ts.net", auth: false)
        let openIP = suggestion("100.64.0.1", auth: false)
        let gated = suggestion("arch.tail.ts.net", auth: true)
        #expect(TailnetScanner.preferred(open, over: gated))
        #expect(TailnetScanner.preferred(open, over: openIP))
        #expect(!TailnetScanner.preferred(gated, over: openIP))
    }
}

private final class Locked<T: Sendable>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()

    init(_ value: T) { self.stored = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
