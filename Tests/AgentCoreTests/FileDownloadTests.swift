import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

/// Serves a fixed body for `download.test` and nothing else, so registering it globally cannot
/// answer another suite's requests.
final class DownloadStubProtocol: URLProtocol {
    static let bytes = Data((0..<300_000).map { UInt8($0 % 251) })

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "download.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let missing = url.path.hasSuffix("missing")
        let response = HTTPURLResponse(
            url: url, statusCode: missing ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": missing ? "0" : String(Self.bytes.count)])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !missing { client.urlProtocol(self, didLoad: Self.bytes) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct FileDownloadTests {
    private var stubbed: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubProtocol.self]
        return configuration
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("filedownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aDownloadLandsOnDiskWhole() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("nested/landed.bin")
        try await FileDownload.perform(
            URLRequest(url: URL(string: "http://download.test/clip.mp4")!), to: target,
            configuration: stubbed)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("nested/.landed.bin.part").path))
        #expect(try Data(contentsOf: target) == DownloadStubProtocol.bytes)
    }

    @Test func aLargeReadComesBackWholeAndLeavesNoFile() async throws {
        let client = HTTPClient(session: URLSession(configuration: stubbed))
        let before = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).count
        let body = try await client.sendLarge(URLRequest(url: URL(string: "http://download.test/page")!))
        #expect(body == DownloadStubProtocol.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).count <= before)
    }

    @Test func aLargeReadThrowsTheServersRefusal() async throws {
        let client = HTTPClient(session: URLSession(configuration: stubbed))
        await #expect(throws: AgentError.http(status: 404, body: "")) {
            try await client.sendLarge(URLRequest(url: URL(string: "http://download.test/missing")!))
        }
    }

    @Test func aMissingFileIsTheServersAnswer() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stubbed = self.stubbed
        await #expect(throws: AgentError.http(status: 404, body: "")) {
            try await FileDownload.perform(
                URLRequest(url: URL(string: "http://download.test/missing")!),
                to: folder.appendingPathComponent("x.bin"), configuration: stubbed)
        }
    }
}
