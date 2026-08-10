import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

private func sse(_ json: String) -> SSEvent {
    SSEvent(id: nil, type: nil, data: json)
}

private let messageWithTwoTextParts =
    #"{"type":"message","message":{"id":"msg_A","role":"assistant","createdAt":"2026-07-17T00:00:00Z","parts":[{"kind":"text","text":"First block"},{"kind":"text","text":"Second block"}]}}"#

private let deltaForMessageA =
    #"{"type":"delta","messageID":"msg_A","delta":"more"}"#

@Suite struct BridgeEventDecoderTests {
    @Test func messageEventUpsertsWithReplacePartsAndDedupedTextIDs() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(sse(messageWithTwoTextParts))
        guard case .messageUpserted(let message, let replaceParts)? = event else {
            Issue.record("expected messageUpserted, got \(String(describing: event))")
            return
        }
        #expect(replaceParts == true)
        #expect(message.id == "msg_A")
        #expect(message.role == .assistant)
        #expect(message.agentType == .claudeCode)
        #expect(message.parts.map(\.id) == ["text", "text-1"])
        #expect(message.parts.compactMap(\.text) == ["First block", "Second block"])
        #expect(message.text == "First blockSecond block")
    }

    @Test func deltaEventNamesNoPartAndLeavesRoutingToTheTranscript() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(sse(deltaForMessageA))
        guard case .partTextDelta(let messageID, let partID, let delta)? = event else {
            Issue.record("expected partTextDelta, got \(String(describing: event))")
            return
        }
        #expect(messageID == "msg_A")
        #expect(partID == nil)
        #expect(delta == "more")
    }

    @Test func toolEventUpsertsToolPartWithParsedJSONInput() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(
            sse(
                #"{"type":"tool","messageID":"msg_A","tool":{"id":"call_1","name":"bash","input":"{\"command\":\"ls -la\"}","output":"file.txt","status":"completed"}}"#
            ))
        guard case .partUpserted(let messageID, let part)? = event, case .tool(let tool) = part.kind
        else {
            Issue.record("expected tool partUpserted, got \(String(describing: event))")
            return
        }
        #expect(messageID == "msg_A")
        #expect(part.id == "call_1")
        #expect(tool.id == "call_1")
        #expect(tool.name == "bash")
        #expect(tool.status == .completed)
        #expect(tool.output == "file.txt")
        #expect(tool.input?["command"]?.stringValue == "ls -la")
    }

    @Test func toolEventToleratesUnparseableInputAsNil() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(
            sse(
                #"{"type":"tool","messageID":"msg_A","tool":{"id":"call_2","name":"bash","input":"not valid json","output":null,"status":"running"}}"#
            ))
        guard case .partUpserted(_, let part)? = event, case .tool(let tool) = part.kind else {
            Issue.record("expected tool partUpserted, got \(String(describing: event))")
            return
        }
        #expect(tool.id == "call_2")
        #expect(tool.status == .running)
        #expect(tool.input == nil)
        #expect(tool.output == nil)
    }

    @Test func statusRunningMapsToRunningAndAnythingElseToIdle() {
        var decoder = BridgeEventDecoder()
        let running = decoder.decode(sse(#"{"type":"status","status":"running"}"#))
        guard case .status(let runningStatus)? = running else {
            Issue.record("expected running status, got \(String(describing: running))")
            return
        }
        #expect(runningStatus == .running)

        let other = decoder.decode(sse(#"{"type":"status","status":"whatever"}"#))
        guard case .status(let otherStatus)? = other else {
            Issue.record("expected idle status, got \(String(describing: other))")
            return
        }
        #expect(otherStatus == .idle)
    }

    @Test func errorEventDecodesFailureWithMessageAndFallback() {
        var decoder = BridgeEventDecoder()
        let withMessage = decoder.decode(sse(#"{"type":"error","error":"boom"}"#))
        guard case .failure(let failure)? = withMessage else {
            Issue.record("expected failure, got \(String(describing: withMessage))")
            return
        }
        #expect(failure.message == "boom")

        let withoutMessage = decoder.decode(sse(#"{"type":"error"}"#))
        guard case .failure(let fallback)? = withoutMessage else {
            Issue.record("expected fallback failure, got \(String(describing: withoutMessage))")
            return
        }
        #expect(fallback.message == "error")
    }

    @Test func malformedAndUnknownPayloadsDecodeToNil() {
        var decoder = BridgeEventDecoder()
        let brokenJSON = decoder.decode(sse(#"{not valid json"#))
        #expect(brokenJSON == nil)

        let nonObjectJSON = decoder.decode(sse(#"[1,2,3]"#))
        #expect(nonObjectJSON == nil)

        let unknownType = decoder.decode(sse(#"{"type":"heartbeat","foo":"bar"}"#))
        #expect(unknownType == nil)

        let missingTypeField = decoder.decode(sse(#"{"foo":"bar"}"#))
        #expect(missingTypeField == nil)
    }

    @Test func malformedMessagePayloadDecodesToNilWithoutCrashing() {
        var decoder = BridgeEventDecoder()
        let missingCreatedAt = decoder.decode(
            sse(#"{"type":"message","message":{"id":"x","role":"assistant","parts":[]}}"#))
        #expect(missingCreatedAt == nil)

        let missingDelta = decoder.decode(sse(#"{"type":"delta","messageID":"msg_A"}"#))
        #expect(missingDelta == nil)

        let missingToolMessageID = decoder.decode(
            sse(
                #"{"type":"tool","tool":{"id":"c","name":"n","input":"{}","output":null,"status":"running"}}"#
            ))
        #expect(missingToolMessageID == nil)
    }

    @Test func deltaLandsInTheNewestTextPartAfterMultiTextPartMessage() {
        var decoder = BridgeEventDecoder()
        var reducer = MessageReducer(agentType: .claudeCode)
        for payload in [messageWithTwoTextParts, deltaForMessageA] {
            guard let event = decoder.decode(sse(payload)) else {
                Issue.record("expected an event for \(payload)")
                return
            }
            reducer.apply(event)
        }

        let parts = reducer.snapshot.first?.parts ?? []
        #expect(parts.map(\.id) == ["text", "text-1"])
        #expect(parts.compactMap(\.text) == ["First block", "Second blockmore"])
    }

    /// A delta names the block its message is currently being written into, so a message the
    /// transcript has never held cannot say where it goes. Inventing a bubble for it would show an
    /// answer starting mid-sentence, out of a transcript that has demonstrably diverged.
    @Test func deltaWithoutItsMessageFabricatesNothing() {
        var decoder = BridgeEventDecoder()
        var reducer = MessageReducer(agentType: .claudeCode)
        guard let event = decoder.decode(sse(deltaForMessageA)) else {
            Issue.record("expected partTextDelta")
            return
        }
        reducer.apply(event)

        #expect(reducer.snapshot.isEmpty)
    }

    @Test func aToolCallMakesTheNextDeltaOpenAFreshTextPart() {
        var decoder = BridgeEventDecoder()
        var reducer = MessageReducer(
            agentType: .claudeCode,
            messages: [
                ChatMessage(
                    id: "m", role: .assistant, agentType: .claudeCode, parts: [],
                    createdAt: Date(timeIntervalSince1970: 0))
            ])
        let payloads = [
            #"{"type":"delta","messageID":"m","delta":"Hel"}"#,
            #"{"type":"delta","messageID":"m","delta":"lo"}"#,
            #"{"type":"tool","messageID":"m","tool":{"id":"t1","name":"bash","input":"{}","output":null,"status":"running"}}"#,
            #"{"type":"delta","messageID":"m","delta":"world"}"#,
        ]
        for payload in payloads {
            guard let event = decoder.decode(sse(payload)) else {
                Issue.record("expected an event for \(payload)")
                return
            }
            reducer.apply(event)
        }

        let parts = reducer.snapshot.first?.parts ?? []
        #expect(parts.map(\.id) == ["text", "t1", "text-1"])
        #expect(parts.compactMap(\.text) == ["Hello", "world"])
    }

    /// The reason the decoder no longer invents part ids. A chat opened while a turn is already
    /// running — or any stream gap, which drops the per-session decoders — meets a transcript that
    /// already holds two text blocks with a tool call between them. A decoder counting from zero
    /// called the live answer "text" and wrote it into the message's first paragraph, above the
    /// tool row, until the next full message rewrote everything at once.
    @Test func aFreshDecoderAgainstALiveTranscriptWritesIntoTheBlockStillGrowing() {
        var reducer = MessageReducer(
            agentType: .claudeCode,
            messages: [
                ChatMessage(
                    id: "msg_A", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(id: "text", kind: .text("First block")),
                        MessagePart(
                            id: "call_1",
                            kind: .tool(
                                ToolCall(id: "call_1", name: "bash", status: .completed))),
                        MessagePart(id: "text-1", kind: .text("Second block")),
                    ],
                    createdAt: Date(timeIntervalSince1970: 0))
            ])
        var decoder = BridgeEventDecoder()
        guard let event = decoder.decode(sse(deltaForMessageA)) else {
            Issue.record("expected partTextDelta")
            return
        }
        reducer.apply(event)

        let parts = reducer.snapshot.first?.parts ?? []
        #expect(parts.map(\.id) == ["text", "call_1", "text-1"])
        #expect(parts.first?.text == "First block")
        #expect(parts.last?.text == "Second blockmore")
    }
}
