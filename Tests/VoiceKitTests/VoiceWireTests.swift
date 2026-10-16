import Foundation
import Testing

@testable import VoiceKit

@Suite struct VoiceWireTests {
    @Test func clientMessagesRoundTrip() throws {
        let messages: [VoiceClientMessage] = [
            .hello(.init(client: .linux, app: "1.2.3", title: "Fix the build")),
            .hello(.init(client: .ios, app: "1.0")),
            .agent(.init(busy: true, digest: "Editing two files", turn: 7)),
            .sent(id: "d1"),
            .refused(id: "d2", reason: "no session"),
            .bye,
        ]
        for message in messages {
            let text = try VoiceCodec.encode(message)
            #expect(try VoiceCodec.decodeClient(text) == message)
        }
    }

    @Test func serverMessagesRoundTrip() throws {
        let messages: [VoiceServerMessage] = [
            .ready(.init(gateway: "0.1.0", model: "nemotron-voicechat")),
            .phase(.hearing, at: 12.5),
            .user(id: "u1", text: "refactor the parser", final: true),
            .say(text: "On it", final: false),
            .dispatch(id: "d1", text: "refactor the parser"),
            .stop,
            .degraded(.runaway, recovering: true),
            .recycled,
            .engine(.loading, progress: 0.4),
            .engine(.stopped, progress: nil),
            .error(code: "engineDown", message: "The voice model is not running"),
        ]
        for message in messages {
            let text = try VoiceCodec.encode(message)
            #expect(try VoiceCodec.decodeServer(text) == message)
        }
    }

    @Test func wireShapeIsStable() throws {
        #expect(
            try VoiceCodec.encode(VoiceServerMessage.dispatch(id: "d1", text: "hi"))
                == #"{"id":"d1","t":"dispatch","text":"hi"}"#)
        #expect(
            try VoiceCodec.encode(VoiceClientMessage.agent(.init(busy: false, digest: "Idle", turn: 3)))
                == #"{"busy":false,"digest":"Idle","t":"agent","turn":3}"#)
        #expect(try VoiceCodec.encode(VoiceServerMessage.stop) == #"{"t":"stop"}"#)
        #expect(
            try VoiceCodec.encode(VoiceServerMessage.engine(.loading, progress: 0.5))
                == #"{"progress":0.5,"state":"loading","t":"engine"}"#)
    }

    @Test func aNewerPeerDoesNotBreakAnOlderOne() throws {
        #expect(try VoiceCodec.decodeServer(#"{"t":"level","rms":0.2}"#) == .unknown("level"))
        #expect(try VoiceCodec.decodeClient(#"{"t":"mute","on":true}"#) == .unknown("mute"))
        let withExtra = #"{"t":"phase","phase":"speaking","at":3,"extra":1}"#
        #expect(try VoiceCodec.decodeServer(withExtra) == .phase(.speaking, at: 3))
    }

    @Test func anUnknownEngineStateReadsAsDown() throws {
        let text = #"{"t":"engine","state":"warming"}"#
        #expect(try VoiceCodec.decodeServer(text) == .engine(.down, progress: nil))
    }

    @Test func healthUsesTheProtocolKey() throws {
        let health = VoiceHealth(gateway: "0.1.0", engine: .loading, detail: "Loading the model")
        let data = try JSONEncoder().encode(health)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? Int == VoiceWire.version)
        #expect(try JSONDecoder().decode(VoiceHealth.self, from: data) == health)
    }

    @Test func asciiFoldsAccentsAndDropsTheRest() {
        #expect(VoiceText.ascii("Café déjà vu") == "Cafe deja vu")
        #expect(VoiceText.ascii("run `swift test` — now…") == "run `swift test` now")
        #expect(VoiceText.ascii("  many   spaces\n\there  ") == "many spaces here")
        #expect(VoiceText.ascii("日本語 only") == "only")
        #expect(VoiceText.ascii("") == "")
    }

    @Test func asciiCutsAtAWord() {
        let text = "one two three four five six seven eight nine ten"
        let cut = VoiceText.ascii(text, limit: 20)
        #expect(cut.count <= 20)
        #expect(text.hasPrefix(cut))
        #expect(!cut.hasSuffix(" "))
        #expect(VoiceText.ascii("short", limit: 20) == "short")
    }

    @Test func everyAsciiResultIsAscii() {
        let nasty = "Zażółć gęślą jaźń \u{1F600} ‘quotes’ “here” \u{0000}\u{0007}"
        let out = VoiceText.ascii(nasty)
        #expect(out.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 })
    }
}
