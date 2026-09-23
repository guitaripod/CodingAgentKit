import AgentCore
import Foundation

/// opencode 2's stream read as the Kit's events, for one session.
///
/// The stream narrates a turn as steps: a step opens an assistant message, prose and thoughts
/// arrive as started/delta/ended triples counted by ordinal, a tool call as its input, its call,
/// and its result, and the step closes with the turn's finish word and its bill. Each of those
/// becomes the part or message change it amounts to, addressed by the same ids the transcript
/// mapping cuts from the stored record, so a stream and a re-read describe one conversation.
///
/// A little is remembered between frames: what a tool call was named and given, because the
/// result frame repeats neither and the reducer replaces a part whole; and what a prompt said,
/// because the frame that makes it part of the conversation carries only its id.
struct OpenCodeV2EventDecoder {
    let sessionID: String
    private var toolNames: [String: String] = [:]
    private var toolInputs: [String: JSONValue] = [:]
    private var prompts: [String: JSONValue] = [:]

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    static func frame(_ event: SSEvent) -> OC2Event? {
        guard let data = event.data.data(using: .utf8) else { return nil }
        return try? JSONCoding.decoder.decode(OC2Event.self, from: data)
    }

    mutating func decode(_ event: SSEvent) -> [BackendEvent] {
        guard let frame = Self.frame(event) else { return [] }
        return decode(frame)
    }

    mutating func decode(_ frame: OC2Event) -> [BackendEvent] {
        let data = frame.data
        if frame.type == "server.connected" { return [.attached] }
        let owner = data?["sessionID"]?.stringValue ?? data?["form"]?["sessionID"]?.stringValue
        guard let owner else { return [] }
        guard owner == sessionID else { return [] }
        let at = OpenCodeV2Mapping.date(frame.created)

        switch frame.type {
        case "session.step.started":
            guard let messageID = data?["assistantMessageID"]?.stringValue else { return [] }
            let model = data?["model"]
            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                agentType: .openCode,
                createdAt: OpenCodeV2Mapping.date(data?["started"]?.doubleValue ?? frame.created),
                isStreaming: true,
                providerID: model?["providerID"]?.stringValue,
                modelID: model?["id"]?.stringValue,
                reasoningEffort: model?["variant"]?.stringValue)
            return [.messageUpserted(message, replaceParts: false), .status(.running)]

        case "session.step.ended":
            guard let messageID = data?["assistantMessageID"]?.stringValue else { return [] }
            var message = ChatMessage(
                id: messageID, role: .assistant, agentType: .openCode, createdAt: at,
                completedAt: at, isStreaming: false)
            message.costUSD = data?["cost"]?.doubleValue
            message.usage = usage(data?["tokens"])
            message.context = message.usage
            message.totalTokens = message.usage?.total
            message.finishReason = data?["finish"]?.stringValue
            return [.messageUpserted(message, replaceParts: false)]

        case "session.step.failed":
            guard let messageID = data?["assistantMessageID"]?.stringValue else { return [] }
            let reason = OpenCodeV2Mapping.errorMessage(data?["error"]) ?? "step failed"
            var message = ChatMessage(
                id: messageID, role: .assistant, agentType: .openCode, createdAt: at,
                completedAt: at, isStreaming: false, error: reason)
            message.finishReason = data?["finish"]?.stringValue ?? "error"
            return [
                .messageUpserted(message, replaceParts: false),
                .failure(BackendFailure(message: reason)),
            ]

        case "session.text.started":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init)
            else { return [] }
            return [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.textPartID(messageID, ordinal: ordinal),
                        kind: .text(""), startedAt: at))
            ]

        case "session.text.delta":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init),
                let delta = data?["delta"]?.stringValue
            else { return [] }
            return [
                .partTextDelta(
                    messageID: messageID,
                    partID: OpenCodeV2Mapping.textPartID(messageID, ordinal: ordinal), delta: delta)
            ]

        case "session.text.ended":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init)
            else { return [] }
            return [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.textPartID(messageID, ordinal: ordinal),
                        kind: .text(data?["text"]?.stringValue ?? "")))
            ]

        case "session.reasoning.started":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init)
            else { return [] }
            return [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.reasoningPartID(messageID, ordinal: ordinal),
                        kind: .reasoning(""), startedAt: at))
            ]

        case "session.reasoning.delta":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init),
                let delta = data?["delta"]?.stringValue
            else { return [] }
            return [
                .partTextDelta(
                    messageID: messageID,
                    partID: OpenCodeV2Mapping.reasoningPartID(messageID, ordinal: ordinal),
                    delta: delta)
            ]

        case "session.reasoning.ended":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let ordinal = data?["ordinal"]?.intValue.map(Int.init)
            else { return [] }
            let partID = OpenCodeV2Mapping.reasoningPartID(messageID, ordinal: ordinal)
            let text = data?["text"]?.stringValue ?? ""
            /// A thought the provider kept to itself arrives as an empty block; an empty thought
            /// is not a row, so it goes rather than standing as a heading over nothing.
            guard !text.isEmpty else { return [.partRemoved(messageID: messageID, partID: partID)] }
            return [.partUpserted(messageID: messageID, MessagePart(id: partID, kind: .reasoning(text)))]

        case "session.tool.input.started":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let callID = data?["id"]?.stringValue
            else { return [] }
            let name = data?["name"]?.stringValue ?? "tool"
            toolNames[callID] = name
            return [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.toolPartID(messageID, callID: callID),
                        kind: .tool(ToolCall(id: callID, name: name, status: .pending))))
            ]

        case "session.tool.input.delta", "session.tool.input.ended", "session.tool.progress":
            return []

        case "session.tool.called":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let callID = data?["id"]?.stringValue
            else { return [] }
            let name = data?["name"]?.stringValue ?? toolNames[callID] ?? "tool"
            toolNames[callID] = name
            if let input = data?["input"] { toolInputs[callID] = input }
            return [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.toolPartID(messageID, callID: callID),
                        kind: .tool(
                            ToolCall(
                                id: callID, name: name, status: .running,
                                input: toolInputs[callID]))))
            ]

        case "session.tool.success", "session.tool.failed":
            guard let messageID = data?["assistantMessageID"]?.stringValue,
                let callID = data?["id"]?.stringValue
            else { return [] }
            let failed = frame.type == "session.tool.failed"
            let content = toolContent(data?["content"])
            let text = content.compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
            let error = OpenCodeV2Mapping.errorMessage(data?["error"])
            let output = text.isEmpty ? error : text
            let title = data?["metadata"]?["title"]?.stringValue
            var events: [BackendEvent] = [
                .partUpserted(
                    messageID: messageID,
                    MessagePart(
                        id: OpenCodeV2Mapping.toolPartID(messageID, callID: callID),
                        kind: .tool(
                            ToolCall(
                                id: callID, name: toolNames[callID] ?? "tool",
                                status: failed ? .error : .completed,
                                input: toolInputs[callID], output: output, title: title))))
            ]
            for part in OpenCodeV2Mapping.toolFiles(content, messageID: messageID, callID: callID) {
                events.append(.partUpserted(messageID: messageID, part))
            }
            toolNames[callID] = nil
            toolInputs[callID] = nil
            return events

        case "session.execution.started":
            return [.status(.running)]

        case "session.execution.succeeded", "session.execution.interrupted", "session.idle":
            return [.status(.idle)]

        case "session.execution.failed":
            let reason = OpenCodeV2Mapping.errorMessage(data?["error"]) ?? "session error"
            return [.failure(BackendFailure(message: reason)), .status(.idle)]

        case "session.status":
            guard let type = data?["status"]?["type"]?.stringValue else { return [] }
            switch type {
            case "idle":
                return [.status(.idle)]
            case "busy", "running", "retry":
                /// A turn waiting on the provider between attempts is a turn in flight: the
                /// server has not given up on it, and a wall it does give up on arrives as a
                /// failure of its own.
                return [.status(.running)]
            default:
                return [.unknown(type: "session.status.\(type)")]
            }

        case "session.compaction.started":
            return [.compaction(CompactionActivity(startedAt: at))]

        case "session.compaction.delta":
            return []

        case "session.compaction.ended", "session.compacted":
            return [.compaction(nil)]

        case "session.compaction.failed":
            let reason =
                OpenCodeV2Mapping.errorMessage(data?["error"])
                ?? CompactionActivity.unexplainedFailure
            return [.compaction(CompactionActivity(startedAt: at, failure: reason))]

        case "permission.asked":
            guard let value = data, let request = Self.permission(from: value) else { return [] }
            return [.permission(OpenCodeV2Mapping.permission(request))]

        case "permission.replied":
            guard let requestID = data?["requestID"]?.stringValue else { return [] }
            return [.permissionResolved(requestID: requestID)]

        case "form.created":
            guard let value = data?["form"], let form = Self.form(from: value),
                let question = OpenCodeV2Mapping.question(form)
            else { return [] }
            return [.question(question)]

        case "form.replied", "form.cancelled":
            guard let formID = data?["id"]?.stringValue else { return [] }
            return [.questionResolved(requestID: formID)]

        case "session.inbox.enqueued":
            guard let inboxID = data?["inboxID"]?.stringValue, data?["item"]?["type"]?.stringValue == "user",
                let payload = data?["item"]?["payload"]
            else { return [] }
            prompts[inboxID] = payload
            return []

        case "session.inbox.delivered":
            guard let inboxID = data?["inboxID"]?.stringValue, let payload = prompts.removeValue(forKey: inboxID)
            else { return [] }
            return Self.prompt(id: inboxID, payload: payload, created: frame.created).map {
                [.messageUpserted($0, replaceParts: true)]
            } ?? []

        case "session.inbox.cancelled":
            if let inboxID = data?["inboxID"]?.stringValue { prompts[inboxID] = nil }
            return []

        case "session.inbox.delivery.changed", "session.instructions.updated",
            "session.usage.updated", "session.step.streamed", "session.created",
            "session.renamed", "session.deleted", "session.model.selected",
            "session.agent.selected", "session.viewed", "session.retry.scheduled",
            "session.synthetic", "session.skill.activated", "session.shell.started",
            "session.shell.ended", "session.revert.staged", "session.revert.cleared",
            "session.revert.committed", "session.moved", "session.forked",
            "session.permissions":
            return []

        default:
            return [.unknown(type: frame.type)]
        }
    }

    private func usage(_ tokens: JSONValue?) -> MessageUsage? {
        guard let tokens else { return nil }
        let usage = MessageUsage(
            input: Int(tokens["input"]?.intValue ?? 0),
            output: Int(tokens["output"]?.intValue ?? 0),
            reasoning: Int(tokens["reasoning"]?.intValue ?? 0),
            cacheRead: Int(tokens["cache"]?["read"]?.intValue ?? 0),
            cacheWrite: Int(tokens["cache"]?["write"]?.intValue ?? 0))
        return usage.isEmpty ? nil : usage
    }

    private func toolContent(_ value: JSONValue?) -> [OC2ToolContent] {
        guard let value, let data = try? JSONCoding.encoder.encode(value) else { return [] }
        return (try? JSONCoding.decoder.decode([OC2ToolContent].self, from: data)) ?? []
    }

    /// A delivered prompt as the user message a re-read of the transcript would show: opencode 2
    /// announces a prompt only through its inbox, and the message's id is the inbox entry's.
    private static func prompt(id: String, payload: JSONValue, created: Double?) -> ChatMessage? {
        let record: JSONValue = .object([
            "id": .string(id),
            "type": .string("user"),
            "text": payload["text"] ?? .null,
            "files": payload["files"] ?? .null,
            "time": created.map { .object(["created": .number($0)]) } ?? .null,
        ])
        guard let data = try? JSONCoding.encoder.encode(record),
            let message = try? JSONCoding.decoder.decode(OC2Message.self, from: data)
        else { return nil }
        return OpenCodeV2Mapping.user(message)
    }

    private static func permission(from value: JSONValue) -> OC2Permission? {
        guard let data = try? JSONCoding.encoder.encode(value) else { return nil }
        return try? JSONCoding.decoder.decode(OC2Permission.self, from: data)
    }

    private static func form(from value: JSONValue) -> OC2Form? {
        guard let data = try? JSONCoding.encoder.encode(value) else { return nil }
        return try? JSONCoding.decoder.decode(OC2Form.self, from: data)
    }
}
