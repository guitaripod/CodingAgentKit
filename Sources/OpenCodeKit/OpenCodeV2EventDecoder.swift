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
/// result frame repeats neither and the reducer replaces a part whole; what a prompt said,
/// because the frame that makes it part of the conversation carries only its id; which message
/// a running shell was given, because the frame that ends it names only the shell; and the wait
/// the turn is in, because the provider's remedy arrives on one frame and the next attempt's
/// clock on another.
struct OpenCodeV2EventDecoder {
    let sessionID: String
    private var toolNames: [String: String] = [:]
    private var toolInputs: [String: JSONValue] = [:]
    private var prompts: [String: JSONValue] = [:]
    private var shells: [String: String] = [:]
    private var retry: TurnRetry?
    /// Whether this stream has seen the conversation under way, which is what makes a first
    /// model or agent choice a switch rather than the setup of a conversation about to start.
    private var underway = false

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
            underway = true
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
            return [.messageUpserted(message, replaceParts: false), .status(.running)] + settleRetry()

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
            let halted = OpenCodeV2Mapping.halted(data?["error"])
            let reason = OpenCodeV2Mapping.errorMessage(data?["error"]) ?? "step failed"
            var message = ChatMessage(
                id: messageID, role: .assistant, agentType: .openCode, createdAt: at,
                completedAt: at, isStreaming: false, error: halted ? nil : reason)
            message.costUSD = data?["cost"]?.doubleValue
            message.usage = usage(data?["tokens"])
            message.context = message.usage
            message.totalTokens = message.usage?.total
            message.finishReason = halted ? "aborted" : data?["finish"]?.stringValue ?? "error"
            guard !halted else { return [.messageUpserted(message, replaceParts: false)] }
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
            return settleRetry() + [.status(.idle)]

        case "session.execution.failed":
            let reason = OpenCodeV2Mapping.errorMessage(data?["error"]) ?? "session error"
            return settleRetry() + [.failure(BackendFailure(message: reason)), .status(.idle)]

        case "session.status":
            guard let status = data?["status"], let type = status["type"]?.stringValue else {
                return []
            }
            switch type {
            case "idle":
                return settleRetry() + [.status(.idle)]
            case "busy", "running":
                return settleRetry() + [.status(.running)]
            case "retry":
                /// A turn waiting on the provider between attempts is a turn in flight: the
                /// server has not given up on it, and a wall it does give up on arrives as a
                /// failure of its own. What it is waiting on is the news.
                let waiting = Self.waiting(status, remembered: retry)
                retry = waiting
                return [.status(.running), .retry(waiting)]
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
            guard let inboxID = data?["inboxID"]?.stringValue, let item = data?["item"],
                let kind = item["type"]?.stringValue, kind == "user" || kind == "synthetic",
                let payload = item["payload"]
            else { return [] }
            prompts[inboxID] = .object(["type": .string(kind), "payload": payload])
            if kind == "user" { underway = true }
            return []

        case "session.inbox.delivered":
            guard let inboxID = data?["inboxID"]?.stringValue,
                let held = prompts.removeValue(forKey: inboxID), let payload = held["payload"]
            else { return [] }
            if held["type"]?.stringValue == "synthetic" {
                guard
                    let subject = OpenCodeV2Mapping.syntheticSubject(
                        description: payload["description"]?.stringValue,
                        metadata: payload["metadata"])
                else { return [] }
                return [
                    .messageUpserted(
                        OpenCodeV2Mapping.note(id: inboxID, created: frame.created, subject: subject),
                        replaceParts: true)
                ]
            }
            return Self.prompt(id: inboxID, payload: payload, created: frame.created).map {
                [.messageUpserted($0, replaceParts: true)]
            } ?? []

        case "session.shell.started":
            guard let shell = data?["shell"], let shellID = shell["id"]?.stringValue,
                let eventID = frame.id, eventID.hasPrefix("evt_")
            else { return [] }
            let messageID = "msg_" + eventID.dropFirst("evt_".count)
            shells[shellID] = messageID
            return Self.shell(id: messageID, shell: shell, output: nil, created: frame.created, completed: nil)
                .map { [.messageUpserted($0, replaceParts: true)] } ?? []

        case "session.shell.ended":
            guard let shell = data?["shell"], let shellID = shell["id"]?.stringValue,
                let messageID = shells.removeValue(forKey: shellID)
            else { return [] }
            return Self.shell(
                id: messageID, shell: shell, output: data?["output"], created: shell["time"]?["started"]?.doubleValue,
                completed: frame.created
            ).map { [.messageUpserted($0, replaceParts: true)] } ?? []

        case "session.inbox.cancelled":
            if let inboxID = data?["inboxID"]?.stringValue { prompts[inboxID] = nil }
            return []

        case "session.retry.scheduled":
            let attempt = data?["attempt"]?.intValue.map(Int.init) ?? 1
            let reason = OpenCodeV2Mapping.errorMessage(data?["error"]) ?? ""
            let next = OpenCodeV2Mapping.optionalDate(data?["at"]?.doubleValue)
            var waiting = TurnRetry(attempt: attempt, reason: reason, nextAttemptAt: next)
            if let held = retry, held.attempt == attempt {
                waiting.remedy = held.remedy
                if waiting.reason.isEmpty { waiting.reason = held.reason }
                if waiting.nextAttemptAt == nil { waiting.nextAttemptAt = held.nextAttemptAt }
            }
            retry = waiting
            return [.retry(waiting)]

        case "session.model.selected":
            guard underway || data?["previous"] != nil,
                let subject = OpenCodeV2Mapping.modelNote(
                    OpenCodeV2Mapping.modelSelection(data?["model"]),
                    effort: data?["model"]?["variant"]?.stringValue,
                    previous: OpenCodeV2Mapping.modelSelection(data?["previous"]))
            else { return [] }
            return noted(frame, subject)

        case "session.agent.selected":
            guard underway || data?["previous"] != nil,
                let subject = OpenCodeV2Mapping.agentNote(
                    data?["agent"]?.stringValue, previous: data?["previous"]?.stringValue)
            else { return [] }
            return noted(frame, subject)

        case "session.moved":
            guard let directory = data?["location"]?["directory"]?.stringValue, !directory.isEmpty
            else { return [] }
            return noted(frame, .moved(directory))

        case "session.skill.activated":
            guard let name = data?["name"]?.stringValue, !name.isEmpty else { return [] }
            return noted(frame, .skill(name))

        case "session.synthetic":
            guard
                let subject = OpenCodeV2Mapping.syntheticSubject(
                    description: data?["description"]?.stringValue, metadata: data?["metadata"])
            else { return [] }
            return noted(frame, subject)

        case "session.revert.staged":
            guard let value = data?["revert"], let revert = Self.revert(from: value) else { return [] }
            return [.revert(OpenCodeV2Mapping.revert(revert))]

        case "session.revert.cleared":
            return [.revert(nil)]

        case "session.revert.committed":
            return [.revert(nil), .resync]

        case "session.inbox.delivery.changed", "session.usage.updated", "session.step.streamed",
            "session.created", "session.renamed", "session.deleted", "session.viewed",
            "session.forked", "session.permissions", "session.instructions.updated":
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
        record([
            "id": .string(id),
            "type": .string("user"),
            "text": payload["text"] ?? .null,
            "files": payload["files"] ?? .null,
            "time": created.map { .object(["created": .number($0)]) } ?? .null,
        ]).map(OpenCodeV2Mapping.user)
    }

    /// A shell run beside the conversation as the message a re-read would show: opencode 2 keeps it
    /// under the id of the frame that started it, and fills in its end when the shell exits.
    private static func shell(
        id: String, shell: JSONValue, output: JSONValue?, created: Double?, completed: Double?
    ) -> ChatMessage? {
        var time: [String: JSONValue] = [:]
        if let created { time["created"] = .number(created) }
        if let completed { time["completed"] = .number(completed) }
        return record([
            "id": .string(id),
            "type": .string("shell"),
            "shellID": shell["id"] ?? .null,
            "command": shell["command"] ?? .null,
            "status": shell["status"] ?? .null,
            "exit": shell["exit"] ?? .null,
            "output": output ?? .null,
            "time": .object(time),
        ]).map(OpenCodeV2Mapping.shellMessage)
    }

    private static func record(_ fields: [String: JSONValue]) -> OC2Message? {
        guard let data = try? JSONCoding.encoder.encode(JSONValue.object(fields)) else { return nil }
        return try? JSONCoding.decoder.decode(OC2Message.self, from: data)
    }

    /// Ends the wait the turn was in, announcing it only when there was one.
    private mutating func settleRetry() -> [BackendEvent] {
        guard retry != nil else { return [] }
        retry = nil
        return [.retry(nil)]
    }

    /// The wait a `retry` status describes: which attempt, the provider's words, when the next
    /// attempt goes, and what the provider says would end it. A status that names the attempt
    /// already held keeps the clock the schedule gave it where the status carries none.
    private static func waiting(_ status: JSONValue, remembered: TurnRetry?) -> TurnRetry {
        let attempt = status["attempt"]?.intValue.map(Int.init) ?? remembered?.attempt ?? 1
        var waiting = TurnRetry(
            attempt: attempt,
            reason: status["message"]?.stringValue ?? "",
            nextAttemptAt: OpenCodeV2Mapping.optionalDate(status["next"]?.doubleValue))
        if let action = status["action"], let title = action["title"]?.stringValue,
            let message = action["message"]?.stringValue, let label = action["label"]?.stringValue
        {
            waiting.remedy = TurnRetry.Remedy(
                title: title, message: message, label: label, link: action["link"]?.stringValue)
        }
        if let remembered, remembered.attempt == attempt {
            if waiting.nextAttemptAt == nil { waiting.nextAttemptAt = remembered.nextAttemptAt }
            if waiting.reason.isEmpty { waiting.reason = remembered.reason }
            if waiting.remedy == nil { waiting.remedy = remembered.remedy }
        }
        return waiting
    }

    /// A note the server wrote, under the id opencode derives from the frame that wrote it: the
    /// same id a re-read of the transcript gives the record.
    private func noted(_ frame: OC2Event, _ subject: TranscriptNote.Subject) -> [BackendEvent] {
        guard let eventID = frame.id, eventID.hasPrefix("evt_") else { return [] }
        let messageID = "msg_" + eventID.dropFirst("evt_".count)
        return [
            .messageUpserted(
                OpenCodeV2Mapping.note(id: messageID, created: frame.created, subject: subject),
                replaceParts: true)
        ]
    }

    private static func revert(from value: JSONValue) -> OC2Revert? {
        guard let data = try? JSONCoding.encoder.encode(value) else { return nil }
        return try? JSONCoding.decoder.decode(OC2Revert.self, from: data)
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
