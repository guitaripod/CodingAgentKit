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
