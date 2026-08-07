import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct OpenCodeAttachmentTests {
    @Test func promptRequestEncodesTextAndFileParts() throws {
        let request = OCPromptRequest(
            parts: [
                .text("look at this"),
                .file(mime: "image/png", filename: "shot.png", url: "data:image/png;base64,AAAA"),
            ],
            model: OCModelInput(providerID: "opencode", modelID: "big"),
            agent: nil, variant: nil)

        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"type\":\"file\""))
        #expect(json.contains("\"mime\":"))
        #expect(json.contains("shot.png"))
    }

    @Suite struct AttachmentDataDecoding {
        @Test func decodesBase64DataURL() throws {
            let bytes = Data("hello".utf8)
            let url = "data:text/plain;base64," + bytes.base64EncodedString()
            #expect(OpenCodeBackend.dataURLBytes(url) == bytes)
        }

        @Test func decodesRawDataURL() throws {
            #expect(OpenCodeBackend.dataURLBytes("data:text/plain,hello") == Data("hello".utf8))
        }

        @Test func decodesPercentEncodedPayload() throws {
            #expect(
                OpenCodeBackend.dataURLBytes("data:text/plain,hello%20world")
                    == Data("hello world".utf8))
        }

        @Test func toleratesWhitespaceInBase64() throws {
            let b64 = Data("payload".utf8).base64EncodedString()
            let withNewline = String(b64.prefix(4)) + "\n" + b64.dropFirst(4)
            #expect(
                OpenCodeBackend.dataURLBytes("data:image/png;base64," + withNewline)
                    == Data("payload".utf8))
        }

        @Test func rejectsPlainURLs() throws {
            #expect(OpenCodeBackend.dataURLBytes("http://example.com/x.png") == nil)
            #expect(OpenCodeBackend.dataURLBytes("file:///tmp/x.png") == nil)
        }
    }
}
