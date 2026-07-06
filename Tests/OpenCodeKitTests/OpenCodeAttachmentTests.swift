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
            agent: nil)

        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"type\":\"file\""))
        #expect(json.contains("\"mime\":"))
        #expect(json.contains("shot.png"))
    }
}
