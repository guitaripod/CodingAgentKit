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

    @Test func deltaEventRoutesTextDeltaToOpenTextPart() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(sse(deltaForMessageA))
        guard case .partTextDelta(let messageID, let partID, let delta)? = event else {
            Issue.record("expected partTextDelta, got \(String(describing: event))")
            return
        }
        #expect(messageID == "msg_A")
        #expect(partID == "text")
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

    @Test func deltaRoutesToNewestTextPartAfterMultiTextPartMessage() {
        var decoder = BridgeEventDecoder()
        let upsert = decoder.decode(sse(messageWithTwoTextParts))
        guard case .messageUpserted(let message, _)? = upsert else {
            Issue.record("expected messageUpserted, got \(String(describing: upsert))")
            return
        }
        #expect(message.parts.map(\.id) == ["text", "text-1"])

        let event = decoder.decode(sse(deltaForMessageA))
        guard case .partTextDelta(let messageID, let partID, let delta)? = event else {
            Issue.record("expected partTextDelta, got \(String(describing: event))")
            return
        }
        #expect(messageID == "msg_A")
        #expect(partID == "text-1")
        #expect(partID != "text")
        #expect(delta == "more")
    }

    @Test func deltaWithoutPriorMessageOpensFirstTextPart() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(sse(deltaForMessageA))
        guard case .partTextDelta(_, let partID, _)? = event else {
            Issue.record("expected partTextDelta, got \(String(describing: event))")
            return
        }
        #expect(partID == "text")
    }

    @Test func toolCloseMakesNextDeltaOpenAFreshTextPart() {
        var decoder = BridgeEventDecoder()
        let first = decoder.decode(sse(#"{"type":"delta","messageID":"m","delta":"Hel"}"#))
        let second = decoder.decode(sse(#"{"type":"delta","messageID":"m","delta":"lo"}"#))
        _ = decoder.decode(
            sse(
                #"{"type":"tool","messageID":"m","tool":{"id":"t1","name":"bash","input":"{}","output":null,"status":"running"}}"#
            ))
        let third = decoder.decode(sse(#"{"type":"delta","messageID":"m","delta":"world"}"#))

        guard case .partTextDelta(_, let firstID, _)? = first,
            case .partTextDelta(_, let secondID, _)? = second,
            case .partTextDelta(_, let thirdID, _)? = third
        else {
            Issue.record("expected three text deltas")
            return
        }
        #expect(firstID == "text")
        #expect(secondID == "text")
        #expect(thirdID == "text-1")
    }
}
