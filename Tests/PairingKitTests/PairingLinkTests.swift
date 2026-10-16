import Foundation
import Testing

@testable import PairingKit

@Suite struct PairingLinkTests {
    private func link(
        host: String = "mac.tail1234.ts.net", port: Int = 8787, agent: PairingAgent = .claude,
        name: String? = nil, key: String? = nil
    ) throws -> PairingLink {
        try #require(PairingLink(host: host, port: port, agent: agent, name: name, key: key))
    }

    @Test func buildsTheDocumentedShape() throws {
        let built = try link(name: "Marcus Desktop")
        #expect(
            built.url.absoluteString
                == "tailscode://connect?v=1&host=mac.tail1234.ts.net&port=8787&agent=claude&name=Marcus%20Desktop")
        let keyed = try link(agent: .opencode, key: "p@ss")
        #expect(
            keyed.url.absoluteString
                == "tailscode://connect?v=1&host=mac.tail1234.ts.net&port=8787&agent=opencode&key=p%40ss")
    }

    @Test func everyPrintableCharacterRoundTrips() throws {
        let ascii = String((0x20...0x7E).map { Character(Unicode.Scalar($0)) })
        let names = ["a&b=c#d%e f", String(ascii.prefix(64)), String(ascii.suffix(64)), "😀 café 日本語 👨‍👩‍👧", "%41%zz", "+ plus", "tailscode://connect?v=1"]
        for name in names {
            for key in [nil, ascii, "&key=x#%"] {
                let original = try link(name: name, key: key)
                let parsed = try #require(PairingLink(url: original.url))
                #expect(parsed == original)
                #expect(parsed.name == name)
                #expect(parsed.key == key)
                #expect(PairingLink(string: original.url.absoluteString) == original)
            }
        }
    }

    @Test func nameIsCleanedAndCut() throws {
        #expect(try link(name: "a\u{0}b\nc\td\u{202E}e\u{7F}").name == "abcde")
        #expect(try link(name: "\n\t").name == nil)
        #expect(try link(name: String(repeating: "x", count: 100)).name?.count == 64)
        #expect(try link(name: String(repeating: "😀", count: 100)).name?.count == 64)
        #expect(try link(name: "👨‍👩‍👧").name == "👨‍👩‍👧")
    }

    @Test func keyLengthIsBounded() throws {
        #expect(PairingLink(host: "a.b", port: 1, agent: .omp, key: String(repeating: "k", count: 200)) != nil)
        #expect(PairingLink(host: "a.b", port: 1, agent: .omp, key: String(repeating: "k", count: 201)) == nil)
        #expect(try link(key: "").key == nil)
    }

    @Test func portBounds() {
        #expect(PairingLink(host: "a.b", port: 0, agent: .omp) == nil)
        #expect(PairingLink(host: "a.b", port: 65536, agent: .omp) == nil)
        #expect(PairingLink(host: "a.b", port: -1, agent: .omp) == nil)
        #expect(PairingLink(host: "a.b", port: 65535, agent: .omp) != nil)
        #expect(PairingLink(host: "a.b", port: 1, agent: .omp) != nil)
    }

    @Test func hostSyntax() {
        let good = [
            "mac", "mac.tail1234.ts.net", "MAC.Example.COM", "100.64.0.1", "192.168.1.20", "fd7a:115c:a1e0::1",
            "[fd7a:115c:a1e0:ab12::1]", "::1", "1:2:3:4:5:6:7:8", "a-b.c", "xn--bcher-kva.example",
        ]
        for host in good { #expect(PairingLink(host: host, port: 80, agent: .claude) != nil, "\(host)") }
        let bad = [
            "", " ", "a b", "a_b", "-a.b", "a-.b", "a..b", ".a", "a/b", "a@b", "a?b", "a%20b", "é.com",
            "256.1.1.1", "1.2.3.4.5", "1.2.3", "[::1", "::1]", "[[::1]]", ":::", "1::2::3", "12345::1",
            "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7::8", "g::1", String(repeating: "a", count: 64) + ".com",
            String(repeating: "a.", count: 127) + "a",
        ]
        for host in bad { #expect(PairingLink(host: host, port: 80, agent: .claude) == nil, "\(host)") }
    }

    @Test func hostIsNormalized() throws {
        #expect(try link(host: "MAC.TS.NET").host == "mac.ts.net")
        let v6 = try link(host: "[FD7A::1]")
        #expect(v6.host == "fd7a::1")
        #expect(v6.bracketedHost == "[fd7a::1]")
        #expect(try link(host: "mac").bracketedHost == "mac")
    }

    @Test func parsesAFullLink() throws {
        let text = "tailscode://connect?v=1&host=100.101.102.103&port=4096&agent=omp&name=Studio%20Mac&key=s3cret"
        let parsed = try #require(PairingLink(string: text))
        #expect(parsed.host == "100.101.102.103")
        #expect(parsed.port == 4096)
        #expect(parsed.agent == .omp)
        #expect(parsed.name == "Studio Mac")
        #expect(parsed.key == "s3cret")
        #expect(PairingLink(url: try #require(URL(string: text))) == parsed)
    }

    @Test func versionRules() {
        let rest = "&host=a.b&port=1&agent=claude"
        #expect(PairingLink(string: "tailscode://connect?v=1\(rest)") != nil)
        #expect(PairingLink(string: "tailscode://connect?v=2\(rest)&future=yes") != nil)
        #expect(PairingLink(string: "tailscode://connect?v=17\(rest)") != nil)
        #expect(PairingLink(string: "tailscode://connect?\(rest.dropFirst())") != nil)
        #expect(PairingLink(string: "tailscode://connect?v=0\(rest)") == nil)
        #expect(PairingLink(string: "tailscode://connect?v=x\(rest)") == nil)
        #expect(PairingLink(string: "tailscode://connect?v=\(rest)") == nil)
        #expect(PairingLink(string: "tailscode://connect?v=-1\(rest)") == nil)
        #expect(PairingLink(string: "tailscode://connect?v=2&host=a.b&agent=claude") == nil)
    }

    @Test func rejectsWhatIsNotStrictlyOurs() {
        let query = "?v=1&host=a.b&port=1&agent=claude"
        let rejected = [
            "http://connect\(query)", "tailscode://pair\(query)", "tailscode://connect/\(query)",
            "tailscode://connect/x\(query)", "tailscode://user@connect\(query)",
            "tailscode://user:pw@connect\(query)", "tailscode://connect:80\(query)", "tailscode:connect\(query)",
            "tailscode:///connect\(query)", "tailscode://connect\(query)#frag", "tailscode://connect\(query)&host=c.d",
            "tailscode://connect\(query)&v=1", "tailscode://connect\(query)&x=1&x=2", "tailscode://connect\(query)&",
            "tailscode://connect\(query)&&x=1", "tailscode://connect\(query)&flag",
            "tailscode://connect?host=a.b&port=1", "tailscode://connect?v=1&host=a.b&port=1&agent=gemini",
            "tailscode://connect?v=1&host=a.b&port=1&agent=Claude", "tailscode://connect?v=1&host=a.b&port=1&agent=",
            "tailscode://connect?v=1&host=a.b&port=0&agent=omp", "tailscode://connect?v=1&host=a.b&port=65536&agent=omp",
            "tailscode://connect?v=1&host=a.b&port=http&agent=omp", "tailscode://connect?v=1&host=a.b&port=-5&agent=omp",
            "tailscode://connect?v=1&host=a.b&port=%2B80&agent=omp", "tailscode://connect?v=1&host=a.b&port=&agent=omp",
            "tailscode://connect?v=1&host=a.b&port=80000000000000000000&agent=omp",
            "tailscode://connect?v=1&host=a%20b&port=1&agent=omp", "tailscode://connect?v=1&host=&port=1&agent=omp",
            "tailscode://connect?v=1&host=a/b&port=1&agent=omp", "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=%ZZ",
            "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=%", "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=%C3",
            "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=%FF%FE", "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=é",
            "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=a b", "tailscode://connect?v=1&host=a.b&port=1&agent=omp&=x",
            "tailscode://connect?v=1&host=a.b&port=1&agent=omp&key=\(String(repeating: "k", count: 201))",
            "tailscode://connect?v=1&host=a.b&port=1&agent=omp&" + String(repeating: "x", count: 3000),
            "", "tailscode://", "tailscode://connect", "tailscode://connect?", "connect?v=1", "?",
        ]
        for text in rejected { #expect(PairingLink(string: text) == nil, "\(text.prefix(120))") }
    }

    @Test func acceptsHarmlessVariations() {
        let query = "?v=1&host=a.b&port=1&agent=claude"
        #expect(PairingLink(string: "TAILSCODE://CONNECT\(query)") != nil)
        #expect(PairingLink(string: "  tailscode://connect\(query)\n") != nil)
        #expect(PairingLink(string: "tailscode://connect?agent=claude&port=1&host=a.b") != nil)
        #expect(PairingLink(string: "tailscode://connect\(query)&utm=1") != nil)
        #expect(PairingLink(string: "tailscode://connect\(query)&name=&key=")?.name == nil)
    }

    @Test func tailnetHeuristics() {
        let tailnet = [
            "100.64.0.0", "100.100.1.1", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:6200:1",
            "[fd7a:115c:a1e0::1]", "mac.tail1234.ts.net", "MAC.TS.NET",
        ]
        for host in tailnet { #expect(PairingLink.isTailnetAddress(host), "\(host)") }
        let other = [
            "100.63.255.255", "100.128.0.0", "10.0.0.1", "192.168.1.1", "8.8.8.8", "fd7a:115c:a1e1::1",
            "fd7b:115c:a1e0::1", "::1", "example.com", "ts.net", ".ts.net", "mac.ts.net.evil.com", "evilts.net",
            "mac", "", "not a host",
        ]
        for host in other { #expect(!PairingLink.isTailnetAddress(host), "\(host)") }
        #expect(PairingLink(host: "100.80.1.1", port: 1, agent: .omp)?.isTailnetAddress == true)
        #expect(PairingLink(host: "192.168.1.5", port: 1, agent: .omp)?.isTailnetAddress == false)
    }

    @Test func descriptionNeverPrintsTheKey() throws {
        let secret = "hunter2-secret"
        let keyed = try link(name: "Desk", key: secret)
        for text in [keyed.redacted, keyed.description, keyed.debugDescription, "\(keyed)", String(describing: keyed)] {
            #expect(!text.contains(secret))
            #expect(text.contains("<redacted>"))
        }
        #expect(!(try link(name: "Desk")).redacted.contains("key"))
    }
}
