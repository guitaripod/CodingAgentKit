import AgentCore
import Foundation
import Testing

@testable import DelegateKit

@Suite struct DelegateDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    /// The daemon's wire keys are snake_case and `class`, which Swift cannot spell as a property.
    @Test func aRunDecodesWithItsPacket() throws {
        let run = try decode(
            DelegateRun.self,
            #"""
            {"id":"01M1Q23QXNC3MV4WFCK282H7NN","packet_id":"01M1Q23QXKP3GAGQFA2303QG6Q","class":"docs",
             "repo":"/tmp/repo","host":"arch","mode":"normal","start_tier":"t3","ceiling":"t3","status":"passed",
             "created_at":"2026-09-04T20:32:11.123456789+00:00","finished_at":null,"passed_tier":"t3","escalations":0,
             "summary":"1 file(s)","packet":{"id":"01M1Q23QXKP3GAGQFA2303QG6Q","class":"docs","goal":"Create FRONTIER.md",
             "paths":["FRONTIER.md"],"repo":"/tmp/repo","created":"2026-09-04T20:32:11+00:00"}}
            """#)
        #expect(run.taskClass == "docs")
        #expect(run.passedTier == "t3")
        #expect(run.packet.paths == ["FRONTIER.md"])
        #expect(run.packet.verify == nil)
        #expect(run.created != nil)
    }

    @Test func aPacketRoundTripsWithoutInventingFields() throws {
        let packet = DelegatePacket(id: "01ABC", taskClass: "rust-mech", goal: "fix add", paths: ["src/lib.rs"], verify: "cargo test")
        let json = String(decoding: try JSONCoding.encoder.encode(packet), as: UTF8.self)
        #expect(json.contains("\"class\":\"rust-mech\""))
        #expect(!json.contains("\"read\""))
        #expect(!json.contains("\"notes\""))
        let back = try decode(DelegatePacket.self, json)
        #expect(back == packet)
    }

    @Test func everyEventKindDecodesAndUnknownKindsSurvive() throws {
        let lines = [
            #"{"run_id":"R","seq":1,"ts":"2026-09-04T19:10:53.886550345+00:00","kind":"run_started","packet_id":"P","class":"docs","start_tier":"t1","ceiling":"t3","mode":"conserve","host":"arch","repo":"/r"}"#,
            #"{"run_id":"R","seq":2,"ts":"2026-09-04T19:10:54+00:00","kind":"tier_selected","tier":"t1","label":"local","runner":"omp","model":"llama-swap/qwen","chain_index":0}"#,
            #"{"run_id":"R","seq":3,"ts":"2026-09-04T19:10:54+00:00","kind":"attempt_started","tier":"t1","attempt":1,"model":"llama-swap/qwen"}"#,
            #"{"run_id":"R","seq":4,"ts":"2026-09-04T19:10:55+00:00","kind":"progress","tier":"t1","attempt":1,"text":"write NOTES.md"}"#,
            #"{"run_id":"R","seq":5,"ts":"2026-09-04T19:10:56+00:00","kind":"attempt_finished","tier":"t1","attempt":1,"status":"fail","verify_exit":101,"duration_ms":1200,"tokens_in":10,"tokens_out":2,"changed_files":["a"],"scope_violations":[],"verify_tail":"boom","worker_summary":"tried"}"#,
            #"{"run_id":"R","seq":6,"ts":"2026-09-04T19:10:56+00:00","kind":"escalated","from":"t1","to":"t2","reason":"t1 failed at 2"}"#,
            #"{"run_id":"R","seq":7,"ts":"2026-09-04T19:10:56+00:00","kind":"chain_failover","tier":"t2","from":"a","to":"b","reason":"402"}"#,
            #"{"run_id":"R","seq":8,"ts":"2026-09-04T19:10:56+00:00","kind":"approval_required","tier":"t3","reason":"mode conserve"}"#,
            #"{"run_id":"R","seq":9,"ts":"2026-09-04T19:10:57+00:00","kind":"approval_resolved","tier":"t3","approved":true}"#,
            #"{"run_id":"R","seq":10,"ts":"2026-09-04T19:10:58+00:00","kind":"tier_skipped","tier":"t2","reason":"unreachable"}"#,
            #"{"run_id":"R","seq":11,"ts":"2026-09-04T19:10:59+00:00","kind":"applied","files":["a"],"patch_bytes":121}"#,
            #"{"run_id":"R","seq":12,"ts":"2026-09-04T19:11:00+00:00","kind":"something_new","tier":"t9"}"#,
            #"{"run_id":"R","seq":13,"ts":"2026-09-04T19:11:01+00:00","kind":"run_finished","status":"passed","passed_tier":"t3","escalations":2,"duration_ms":9000,"summary":"1 file(s)"}"#,
        ]
        let envelopes = try lines.map { try decode(DelegateEnvelope.self, $0) }
        #expect(envelopes.map(\.seq) == Array(1...13))
        guard case .runStarted(_, _, let start, let ceiling, let mode, _, _) = envelopes[0].event else { Issue.record("run_started"); return }
        #expect(start == "t1" && ceiling == "t3" && mode == .conserve)
        guard case .attemptFinished(let outcome) = envelopes[4].event else { Issue.record("attempt_finished"); return }
        #expect(outcome.status == .fail && outcome.verifyExit == 101 && outcome.changedFiles == ["a"])
        guard case .chainFailover(_, let from, let to, _) = envelopes[6].event else { Issue.record("chain_failover"); return }
        #expect(from == "a" && to == "b")
        guard case .unknown(let kind) = envelopes[11].event else { Issue.record("unknown"); return }
        #expect(kind == "something_new")
        #expect(envelopes[12].event.isTerminal)
        #expect(envelopes[0].date != nil)
        #expect(!envelopes[3].event.isTerminal)
    }

    @Test func statsTiersAndCapabilitiesDecode() throws {
        let stats = try decode([DelegateStat].self, #"[{"class":"docs","tier":"t1","attempts":3,"passes":3,"pass_rate":1.0,"avg_ms":5379.3,"tokens_in":171311,"tokens_out":685}]"#)
        #expect(stats.first?.passRate == 1.0)
        let tiers = try decode([DelegateTier].self, #"[{"tier":"t1","label":"local","chain":[{"runner":"omp","model":"a","thinking":"low","health":"http://x","healthy":false,"reason":"down"},{"runner":"omp","model":"b","thinking":null,"health":null,"healthy":null,"reason":null}]}]"#)
        #expect(tiers.first?.activeEntry?.model == "b")
        let caps = try decode(DelegateCapabilities.self, #"{"api":1,"version":"0.1.0","host":"arch","features":["runs"],"tiers":["t1","t2"],"classes":["docs"],"modes":["normal"]}"#)
        #expect(caps.tiers == ["t1", "t2"])
    }

    @Test func aStreamLineWithoutDataIsNotAnEvent() {
        #expect(DelegateClient.parseEnvelope(SSEvent(id: nil, type: nil, data: "")) == nil)
        let good = SSEvent(id: "3", type: "run", data: #"{"run_id":"R","seq":3,"ts":"2026-09-04T19:10:54+00:00","kind":"tier_skipped","tier":"t2","reason":"down"}"#)
        #expect(DelegateClient.parseEnvelope(good)?.seq == 3)
    }

    @Test func mintedIdentifiersSortByTime() {
        let earlier = DelegateIdentifier.mint(now: Date(timeIntervalSince1970: 1_000_000))
        let later = DelegateIdentifier.mint(now: Date(timeIntervalSince1970: 2_000_000))
        #expect(earlier.count == 26 && later.count == 26)
        #expect(earlier.prefix(10) < later.prefix(10))
    }

    @Test func theDaemonConfigUsesTheDaemonUserAndPort() throws {
        let config = try #require(DelegateClient.config(host: "100.91.211.44", password: "pw"))
        #expect(config.baseURL.absoluteString == "http://100.91.211.44:4100")
        #expect(config.credentials?.username == "delegate")
        let request = try RequestBuilder(config: config).request(.get, "/v1/runs")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }
}
