import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct ClaudeCodeDecodingTests {
    @Test func decodesMessageUpdate() {
        let event = ClaudeCodeEventDecoder.decode(
            SSEvent(
                id: nil, type: "message_update",
                data: #"{"id":7,"message":"Hi there","role":"agent","time":"2026-07-06T15:00:00Z"}"#
            ))
        guard case .messageUpserted(let message, let replaceParts)? = event else {
            Issue.record("expected messageUpserted, got \(String(describing: event))")
            return
        }
        #expect(replaceParts == true)
        #expect(message.id == "7")
        #expect(message.role == .assistant)
        #expect(message.agentType == .claudeCode)
        #expect(message.text == "Hi there")
    }

    @Test func decodesStatusChangeAndError() {
        guard
            case .status(.running)? = ClaudeCodeEventDecoder.decode(
                SSEvent(
                    id: nil, type: "status_change",
                    data: #"{"agent_type":"claude","status":"running"}"#))
        else {
            Issue.record("expected running status")
            return
        }
        guard
            case .failure(let failure)? = ClaudeCodeEventDecoder.decode(
                SSEvent(
                    id: nil, type: "agent_error",
                    data: #"{"level":"error","message":"boom","time":"2026-07-06T15:00:00Z"}"#))
        else {
            Issue.record("expected failure")
            return
        }
        #expect(failure.message == "boom")
    }

    @Test func unknownEventTypeFallsBack() {
        guard
            case .unknown(let type)? = ClaudeCodeEventDecoder.decode(
                SSEvent(
                    id: nil, type: "token_usage", data: "{}"))
        else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "token_usage")
    }

    @Test func reducerReplacesGrowingContentFromWholeMessageUpdates() {
        var reducer = MessageReducer(agentType: .claudeCode)
        for content in ["He", "Hello", "Hello!"] {
            let event = ClaudeCodeEventDecoder.decode(
                SSEvent(
                    id: nil, type: "message_update",
                    data:
                        #"{"id":1,"message":"\#(content)","role":"agent","time":"2026-07-06T15:00:00Z"}"#
                ))!
            reducer.apply(event)
        }
        #expect(reducer.snapshot.count == 1)
        #expect(reducer.snapshot.first?.text == "Hello!")
        #expect(reducer.snapshot.first?.role == .assistant)
    }

    @Test func mapsMessageAndParsesRFC3339Date() throws {
        let message = ClaudeCodeMapping.message(
            try JSONCoding.decoder.decode(
                AAMessage.self,
                from: Data(
                    #"{"id":3,"content":"hey","role":"user","time":"2026-07-06T15:00:00Z"}"#.utf8)))
        #expect(message.id == "3")
        #expect(message.role == .user)
        #expect(message.agentType == .claudeCode)
        #expect(message.createdAt.timeIntervalSince1970 > 0)
    }

    @Test func decodesMessagesWrapper() throws {
        let response = try JSONCoding.decoder.decode(
            AAMessagesResponse.self,
            from: Data(
                #"{"messages":[{"id":1,"content":"a","role":"user","time":"2026-07-06T15:00:00Z"},{"id":2,"content":"b","role":"agent","time":"2026-07-06T15:00:01Z"}]}"#
                    .utf8))
        #expect(response.messages.count == 2)
        #expect(ClaudeCodeMapping.message(response.messages[1]).role == .assistant)
    }
}
