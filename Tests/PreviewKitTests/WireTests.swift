import Foundation
import Testing

@testable import PreviewKit

@Suite struct WireTests {
    @Test func statusRoundTrips() throws {
        let status = PreviewStatus(
            version: "0.1.0", host: HostFacts(name: "mac", os: "macOS 27.2", arch: "arm64"),
            xcode: XcodeFacts(version: "27.1", build: "27A9275", path: "/Applications/Xcode.app"),
            runtimes: [], streaming: StreamingFacts(encodings: ["mjpeg"], maximumFramesPerSecond: 60, touch: false, tool: nil))
        let data = try PreviewJSON.encoder.encode(status)
        let back = try PreviewJSON.decoder.decode(PreviewStatus.self, from: data)
        #expect(back == status)
    }
}

@Suite struct ViewWireTests {
    @Test func historyListDecodesWhatTheHostSends() throws {
        let json = """
            [{"id":1,"at":"2026-10-15T09:00:00Z","title":"App opened","trigger":"start","bytes":41000},
             {"id":2,"at":"2026-10-15T09:00:30Z","title":"Shown in 1.8 s","path":"rebuilt","trigger":"edit","bytes":42100}]
            """
        let list = try PreviewJSON.decoder.decode([HistoryInfo].self, from: Data(json.utf8))
        #expect(list.map(\.id) == [1, 2])
        #expect(list[0].path == nil)
        #expect(list[1].path == .rebuilt)
        #expect(list[1].trigger == "edit")
    }

    @Test func diffReportDecodes() throws {
        let json = #"{"width":604,"height":1312,"changed":0.031,"sameSize":true,"regions":[{"x":8,"y":1100,"width":588,"height":56,"changed":0.9}]}"#
        let report = try PreviewJSON.decoder.decode(DiffReport.self, from: Data(json.utf8))
        #expect(report.regions == [DiffRegion(x: 8, y: 1100, width: 588, height: 56, changed: 0.9)])
        #expect(report.sameSize)
    }

    @Test func variantJobDecodesRunningAndFinished() throws {
        let running = #"{"job":"ab12","state":"running","done":1,"total":4,"results":[{"label":"Dark","ok":true,"bytes":51234}]}"#
        let job = try PreviewJSON.decoder.decode(VariantJob.self, from: Data(running.utf8))
        #expect(job.state == .running)
        #expect(job.done == 1)
        #expect(job.total == 4)
        let finished = #"{"state":"done","done":2,"total":2,"results":[{"label":"A","ok":true,"bytes":10},{"label":"B","ok":false,"bytes":0,"error":"sepia is not an appearance"}]}"#
        let done = try PreviewJSON.decoder.decode(VariantJob.self, from: Data(finished.utf8))
        #expect(done.state == .done)
        #expect(done.results[1].ok == false)
        #expect(done.results[1].error == "sepia is not an appearance")
    }

    @Test func variantsRequestEncodesWhatTheHostReads() throws {
        let request = VariantsRequest(
            variants: [VariantSpec(label: "Arabic", arguments: ["-AppleLanguages", "(ar)"])], settle: 0.8)
        let object = try #require(JSONSerialization.jsonObject(with: PreviewJSON.encoder.encode(request)) as? [String: Any])
        #expect(object["settle"] as? Double == 0.8)
        let first = try #require((object["variants"] as? [[String: Any]])?.first)
        #expect(first["label"] as? String == "Arabic")
        #expect(first["arguments"] as? [String] == ["-AppleLanguages", "(ar)"])
        #expect(first["appearance"] == nil)
    }

    @Test func aReplayBodyIsAnOrdinaryFrameStream() throws {
        var body = Data()
        body += FrameCodec.encode(.frame(microseconds: 1_000, jpeg: Data([0xFF, 0xD8, 0x01])))
        body += FrameCodec.encode(.frame(microseconds: 60_000, jpeg: Data([0xFF, 0xD8, 0x02])))
        var decoder = FrameDecoder()
        let records = try decoder.feed(body)
        #expect(records.count == 2)
        #expect(records[1] == .frame(microseconds: 60_000, jpeg: Data([0xFF, 0xD8, 0x02])))
    }
}
