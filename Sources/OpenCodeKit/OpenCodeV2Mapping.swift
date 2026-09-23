import AgentCore
import Foundation

/// opencode 2's records read as the Kit's. A message is a tagged record with its content inline
/// — an assistant message carries its prose, thoughts and tool calls as one `content` array —
/// so the parts are cut from that array with ids the stream can address: prose and thoughts by
/// their per-kind ordinal, which is what the stream counts, and tool calls by the call id the
/// stream names.
enum OpenCodeV2Mapping {
    static func date(_ milliseconds: Double?) -> Date {
        Date(timeIntervalSince1970: (milliseconds ?? 0) / 1000)
    }

    static func optionalDate(_ milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return date(milliseconds)
    }

    /// opencode calls a turn it is running `running` on the process-wide map and `busy` on the
    /// stream; `retry` is a turn waiting on the provider between attempts, which is a turn in
    /// flight rather than a conversation that has settled.
    static func isRunning(_ status: OC2SessionStatus) -> Bool {
        status.type == "busy" || status.type == "running" || status.type == "retry"
    }

    static func isRunning(_ type: String) -> Bool {
        isRunning(OC2SessionStatus(type: type))
    }

    /// The record's own clock: the later of when it was last written to and when its last turn
    /// settled, because opencode stamps `updated` at the prompt and `idle` at the answer.
    static func updatedAt(_ session: OC2Session) -> Date {
        let stamps = [session.time?.updated, session.time?.idle, session.time?.created]
            .compactMap { $0 }
        return date(stamps.max())
    }

    static func session(_ session: OC2Session, running: Bool?) -> AgentSession {
        AgentSession(
            id: session.id,
            agentType: .openCode,
            title: title(session),
            parentID: session.parentID,
            directory: session.location?.directory,
            createdAt: date(session.time?.created),
            updatedAt: updatedAt(session),
            isActive: running,
            model: session.model?.id,
            modelProviderID: session.model?.providerID,
            reasoningEffort: session.model?.variant
        )
    }

    static func title(_ session: OC2Session) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? session.id : title
    }

    static func project(_ project: OC2Project) -> AgentProject? {
        guard let worktree = project.canonical, !worktree.isEmpty else { return nil }
        return AgentProject(
            id: project.id, worktree: worktree,
            updatedAt: optionalDate(project.time?.updated))
    }

    static func subagent(_ session: OC2Session, running: Bool) -> SubagentSummary {
        SubagentSummary(
            id: session.id,
            title: session.title ?? SubagentSummary.untitled,
            updatedAt: updatedAt(session),
            isActive: running,
            isCompleted: !running)
    }

    static func usage(_ tokens: OC2Tokens?) -> MessageUsage? {
        guard let tokens else { return nil }
        let usage = MessageUsage(
            input: Int(tokens.input ?? 0), output: Int(tokens.output ?? 0),
            reasoning: Int(tokens.reasoning ?? 0), cacheRead: Int(tokens.cache?.read ?? 0),
            cacheWrite: Int(tokens.cache?.write ?? 0))
        return usage.isEmpty ? nil : usage
    }

    static func modelSelection(_ model: OC2Model) -> ModelSelection {
        ModelSelection(providerID: model.providerID, modelID: model.modelID ?? model.id)
    }

    static func modelInfo(_ model: OC2Model) -> ModelInfo {
        let input = model.capabilities?.input ?? []
        let image = input.contains("image")
        let pdf = input.contains("pdf")
        return ModelInfo(
            id: model.modelID ?? model.id,
            name: model.name ?? model.modelID ?? model.id,
            providerID: model.providerID,
            capabilities: model.capabilities.map { _ in
                ModelCapabilities(attachment: image || pdf, imageInput: image, pdfInput: pdf)
            },
            variants: OpenCodeCommon.orderedVariants((model.variants ?? []).map(\.id)),
            contextWindow: (model.limit?.context).flatMap { $0 > 0 ? Int($0) : nil })
    }

    static func command(_ command: OC2Command) -> AgentCommand {
        AgentCommand(
            name: command.name, details: command.description ?? "", argumentHint: nil,
            source: .custom)
    }

    static func fileNode(_ entry: OC2FSEntry, root: String? = nil) -> FileNode {
        let isDirectory = entry.type == "directory" || entry.path.hasSuffix("/")
        let relative = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
        let path = root.map { ($0.hasSuffix("/") ? $0 : $0 + "/") + relative } ?? relative
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return FileNode(path: path, name: name, isDirectory: isDirectory)
    }

    static func fileDiff(_ diff: OC2Diff) -> FileDiff {
        FileDiff(
            path: diff.file ?? "", additions: diff.additions ?? 0, deletions: diff.deletions ?? 0,
            patch: diff.patch)
    }

    static func permission(_ request: OC2Permission) -> PermissionRequest {
        PermissionRequest(
            id: request.id,
            sessionID: request.sessionID,
            title: permissionTitle(request),
            toolName: request.action)
    }

    /// What the server asked, in its own words where it gave any, else the action over the
    /// resources it names.
    static func permissionTitle(_ request: OC2Permission) -> String? {
        if let message = request.message, !message.isEmpty { return message }
        let resources = (request.resources ?? []).joined(separator: ", ")
        guard let action = request.action else { return resources.isEmpty ? nil : resources }
        return resources.isEmpty ? action : "\(action) \(resources)"
    }

    /// A form read as a question: one item per field, the field's title as the question and its
    /// description as the header, its options where it has them, and a free answer wherever the
    /// server left room for one. A yes/no field offers the two words a person would type.
    static func question(_ form: OC2Form) -> QuestionRequest? {
        let items = form.fields.compactMap(questionItem)
        guard !items.isEmpty else { return nil }
        return QuestionRequest(id: form.id, sessionID: form.sessionID, questions: items)
    }

    static let yes = "Yes"
    static let no = "No"

    private static func questionItem(_ field: OC2FormField) -> QuestionRequest.Item? {
        let question = field.title ?? field.key
        let header = field.description ?? ""
        switch field.type {
        case "boolean":
            return QuestionRequest.Item(
                question: question, header: header,
                options: [
                    QuestionRequest.Option(label: yes, description: ""),
                    QuestionRequest.Option(label: no, description: ""),
                ])
        case "multiselect":
            return QuestionRequest.Item(
                question: question, header: header,
                options: options(field), multiple: true, custom: field.custom ?? false)
        case "external":
            return QuestionRequest.Item(
                question: question, header: field.url ?? header, options: [], custom: true)
        default:
            let options = options(field)
            return QuestionRequest.Item(
                question: question, header: header, options: options,
                custom: field.custom ?? options.isEmpty)
        }
    }

    private static func options(_ field: OC2FormField) -> [QuestionRequest.Option] {
        (field.options ?? []).map {
            QuestionRequest.Option(label: $0.label, description: $0.description ?? "")
        }
    }

    /// The answers a person gave, written back in the form's own terms: an option's value rather
    /// than its label, a number where the field wants one, a bool for the two words offered.
    static func formAnswer(_ form: OC2Form, answers: [[String]]) -> JSONValue {
        var answer: [String: JSONValue] = [:]
        for (index, field) in form.fields.enumerated() {
            guard index < answers.count else { break }
            let given = answers[index]
            guard let value = formValue(field, given: given) else { continue }
            answer[field.key] = value
        }
        return .object(answer)
    }

    private static func formValue(_ field: OC2FormField, given: [String]) -> JSONValue? {
        let resolved = given.map { label -> String in
            field.options?.first { $0.label == label }?.value ?? label
        }
        switch field.type {
        case "boolean":
            guard let first = given.first else { return nil }
            return .bool(first == yes)
        case "multiselect":
            return .array(resolved.map { .string($0) })
        case "number", "integer":
            guard let first = resolved.first, let number = Double(first) else { return nil }
            return .number(number)
        case "external":
            return nil
        default:
            guard let first = resolved.first else { return nil }
            return .string(first)
        }
    }

    static func shell(_ message: OC2Message) -> ChatMessage {
        let completed = message.time?.completed
        return ChatMessage(
            id: message.id,
            role: .assistant,
            agentType: .openCode,
            parts: [],
            createdAt: date(message.time?.created),
            completedAt: optionalDate(completed),
            isStreaming: completed == nil,
            error: halted(message.error) ? nil : message.error?.message,
            costUSD: message.cost,
            providerID: message.model?.providerID,
            modelID: message.model?.id,
            reasoningEffort: message.model?.variant,
            totalTokens: usage(message.tokens).map(\.total),
            usage: usage(message.tokens),
            context: usage(message.tokens),
            finishReason: halted(message.error) ? "aborted" : message.finish
        )
    }

    /// A step somebody stopped — the turn interrupted, or a tool call they declined — which opencode
    /// records as an error of type `aborted`. It is the person's own decision rather than a failure.
    static func halted(_ error: OC2Error?) -> Bool { error?.type == "aborted" }

    static func halted(_ error: JSONValue?) -> Bool { error?["type"]?.stringValue == "aborted" }

    static func textPartID(_ messageID: String, ordinal: Int) -> String {
        "\(messageID)/text/\(ordinal)"
    }

    static func reasoningPartID(_ messageID: String, ordinal: Int) -> String {
        "\(messageID)/reasoning/\(ordinal)"
    }

    static func toolPartID(_ messageID: String, callID: String) -> String {
        "\(messageID)/tool/\(callID)"
    }

    static func toolFilePartID(_ messageID: String, callID: String, index: Int) -> String {
        "\(messageID)/tool/\(callID)/file/\(index)"
    }

    static func toolStatus(_ raw: String?, messageCompleted: Bool) -> ToolStatus {
        switch raw {
        case "streaming": return messageCompleted ? .stopped : .pending
        case "running": return messageCompleted ? .stopped : .running
        case "completed": return .completed
        case "error": return .error
        default: return .stopped
        }
    }

    /// What a tool answered, as prose: every text block it returned, joined; a failure's own
    /// message when it failed and wrote nothing else.
    static func toolOutput(_ state: OC2ToolState?) -> String? {
        guard let state else { return nil }
        let text = (state.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }
            .joined(separator: "\n")
        if !text.isEmpty { return text }
        return state.error?.message
    }

    static func toolTitle(_ state: OC2ToolState?) -> String? {
        state?.metadata?["title"]?.stringValue
    }

    /// The pictures and files a tool handed back, each a part docked at the call that read it.
    static func toolFiles(
        _ content: [OC2ToolContent]?, messageID: String, callID: String
    ) -> [MessagePart] {
        (content ?? []).filter { $0.type == "file" && $0.uri != nil }.enumerated().map {
            index, file in
            MessagePart(
                id: toolFilePartID(messageID, callID: callID, index: index),
                kind: .file(
                    FileReference(
                        path: nil, mime: file.mime, url: file.uri, filename: displayName(file.name))))
        }
    }

    /// Where a prompt's file can be read back: its bytes as a data URL, since they travel with the
    /// message, or the uri it came from when the server kept none.
    static func promptFileURL(_ file: OC2PromptFile) -> String? {
        if let data = file.data, !data.isEmpty {
            return "data:\(file.mime ?? "application/octet-stream");base64,\(data)"
        }
        return file.source?.uri
    }

    static func displayName(_ filename: String?) -> String? {
        filename.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func toolPart(
        _ content: OC2Content, messageID: String, messageCompleted: Bool
    ) -> MessagePart? {
        guard let callID = content.id else { return nil }
        let input: JSONValue?
        if case .object = content.state?.input { input = content.state?.input } else { input = nil }
        return MessagePart(
            id: toolPartID(messageID, callID: callID),
            kind: .tool(
                ToolCall(
                    id: callID,
                    name: content.name ?? "tool",
                    status: toolStatus(content.state?.status, messageCompleted: messageCompleted),
                    input: input,
                    output: toolOutput(content.state),
                    title: toolTitle(content.state))))
    }

    static func assistant(_ message: OC2Message) -> ChatMessage {
        var result = shell(message)
        let completed = message.time?.completed != nil
        var texts = 0
        var thoughts = 0
        var parts: [MessagePart] = []
        for content in message.content ?? [] {
            switch content.type {
            case "text":
                parts.append(
                    MessagePart(
                        id: textPartID(message.id, ordinal: texts), kind: .text(content.text ?? ""),
                        startedAt: optionalDate(content.time?.created)))
                texts += 1
            case "reasoning":
                let text = content.text ?? ""
                defer { thoughts += 1 }
                guard !text.isEmpty else { continue }
                parts.append(
                    MessagePart(
                        id: reasoningPartID(message.id, ordinal: thoughts), kind: .reasoning(text),
                        startedAt: optionalDate(content.time?.created)))
            case "tool":
                guard let part = toolPart(content, messageID: message.id, messageCompleted: completed)
                else { continue }
                parts.append(part)
                parts.append(
                    contentsOf: toolFiles(
                        content.state?.content, messageID: message.id, callID: content.id ?? ""))
            default:
                parts.append(MessagePart(id: "\(message.id)/\(parts.count)", kind: .unknown(type: content.type)))
            }
        }
        result.parts = parts
        return result
    }

    static func user(_ message: OC2Message) -> ChatMessage {
        var parts: [MessagePart] = []
        if let text = message.text {
            parts.append(MessagePart(id: "\(message.id)/text", kind: .text(text)))
        }
        for (index, file) in (message.files ?? []).enumerated() {
            parts.append(
                MessagePart(
                    id: "\(message.id)/file/\(index)",
                    kind: .file(
                        FileReference(
                            path: nil, mime: file.mime, url: promptFileURL(file),
                            filename: displayName(file.name)))))
        }
        return ChatMessage(
            id: message.id,
            role: .user,
            agentType: .openCode,
            parts: parts,
            createdAt: date(message.time?.created),
            completedAt: optionalDate(message.time?.created))
    }

    /// A shell the person ran beside the conversation, drawn as the tool call it amounts to.
    static func shellMessage(_ message: OC2Message) -> ChatMessage {
        let running = message.status == "running" && message.time?.completed == nil
        let callID = message.shellID ?? message.id
        return ChatMessage(
            id: message.id,
            role: .assistant,
            agentType: .openCode,
            parts: [
                MessagePart(
                    id: toolPartID(message.id, callID: callID),
                    kind: .tool(
                        ToolCall(
                            id: callID,
                            name: "shell",
                            status: running ? .running : shellOutcome(message),
                            input: .object(["command": .string(message.command ?? "")]),
                            output: message.output?.output,
                            title: message.command)))
            ],
            createdAt: date(message.time?.created),
            completedAt: optionalDate(message.time?.completed),
            isStreaming: running)
    }

    /// A finished shell failed when it ran out of time, was killed, or exited non-zero; a killed or
    /// timed-out shell may carry no exit code at all.
    private static func shellOutcome(_ message: OC2Message) -> ToolStatus {
        if message.status == "timeout" || message.status == "killed" { return .error }
        return (message.exit ?? 0) == 0 ? .completed : .error
    }

    static func compactionSeam(_ message: OC2Message) -> ChatMessage {
        let summary = message.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChatMessage(
            id: message.id,
            role: .system,
            agentType: .openCode,
            parts: [
                MessagePart(
                    id: "\(message.id)/compaction",
                    kind: .compaction(
                        Compaction(
                            trigger: message.reason == "auto" ? .auto : .manual,
                            summary: summary.isEmpty ? nil : summary)))
            ],
            createdAt: date(message.time?.created),
            completedAt: optionalDate(message.time?.created))
    }

    /// The whole message list read as a transcript. The server's notes for the reader (a model or
    /// agent switched, a location moved, a skill taken up, and every line it wrote with a
    /// description for display) are drawn as notes; what it wrote for the model alone and the idle
    /// marker that closes a turn draw nothing; a compaction still running is the activity rather
    /// than a row, and one that failed left no seam to show.
    static func transcript(_ messages: [OC2Message]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var prompted = false
        for message in messages {
            switch message.type {
            case "user":
                prompted = true
                result.append(user(message))
            case "assistant":
                result.append(assistant(message))
            case "compaction":
                guard message.status == "completed" else { continue }
                result.append(compactionSeam(message))
            case "shell":
                result.append(shellMessage(message))
            default:
                guard let subject = noteSubject(message) else { continue }
                if !prompted, subject.isSelection { continue }
                result.append(note(id: message.id, created: message.time?.created, subject: subject))
            }
        }
        return result
    }

    /// What a stored bookkeeping record says to the reader, or nil when it says nothing to them.
    static func noteSubject(_ message: OC2Message) -> TranscriptNote.Subject? {
        switch message.type {
        case "model-switched":
            return modelNote(
                message.model.flatMap(modelSelection), effort: message.model?.variant,
                previous: modelSelection(message.previous))
        case "agent-switched":
            return agentNote(message.agent, previous: message.previous?.stringValue)
        case "location-switched":
            guard let directory = message.location?.directory, !directory.isEmpty else { return nil }
            return .moved(directory)
        case "skill":
            guard let name = message.name, !name.isEmpty else { return nil }
            return .skill(name)
        case "synthetic":
            return syntheticSubject(description: message.description, metadata: message.metadata)
        default:
            return nil
        }
    }

    /// A change of model. The model a conversation is set up with before anybody has written in
    /// it is where it starts rather than a switch, which the transcript and the stream each drop.
    static func modelNote(_ model: ModelSelection?, effort: String?, previous: ModelSelection?)
        -> TranscriptNote.Subject?
    {
        guard let model, previous != model else { return nil }
        return .model(model, effort: effort, previous: previous)
    }

    /// A change of agent. opencode also records a switch to the agent already answering, which
    /// changed nothing and is no note.
    static func agentNote(_ agent: String?, previous: String?) -> TranscriptNote.Subject? {
        guard let agent, !agent.isEmpty, previous != agent else { return nil }
        return .agent(agent, previous: previous)
    }

    /// A line written for the model is shown only when the server gave it a description, which is
    /// the server saying it is for the reader too; what kind of line it is comes from what the
    /// server attached to it, and the description is the words.
    static func syntheticSubject(description: String?, metadata: JSONValue?)
        -> TranscriptNote.Subject?
    {
        guard let description = described(description) else { return nil }
        if description == restartDescription { return .resumedAfterRestart }
        let outcome = workOutcome(metadata?["state"]?.stringValue)
        switch metadata?["source"]?.stringValue {
        case "shell":
            return outcome.map { .workFinished(description, work: .command, outcome: $0) }
                ?? .remark(description)
        case "subagent":
            return outcome.map { .workFinished(description, work: .agent, outcome: $0) }
                ?? .remark(description)
        default:
            if metadata?["instruction"] != nil { return .instructions(description) }
            return .remark(description)
        }
    }

    /// The description opencode gives the line that picks a turn back up after a restart.
    static let restartDescription = "Continuing after restart"

    private static func described(_ description: String?) -> String? {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workOutcome(_ state: String?) -> TranscriptNote.Outcome? {
        switch state {
        case "completed": return .completed
        case "cancelled": return .cancelled
        case "error": return .failed
        default: return nil
        }
    }

    static func modelSelection(_ ref: OC2ModelRef) -> ModelSelection? {
        guard let id = ref.id, !id.isEmpty, let provider = ref.providerID, !provider.isEmpty else {
            return nil
        }
        return ModelSelection(providerID: provider, modelID: id)
    }

    static func modelSelection(_ value: JSONValue?) -> ModelSelection? {
        guard let id = value?["id"]?.stringValue, !id.isEmpty,
            let provider = value?["providerID"]?.stringValue, !provider.isEmpty
        else { return nil }
        return ModelSelection(providerID: provider, modelID: id)
    }

    static func note(id: String, created: Double?, subject: TranscriptNote.Subject) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .system,
            agentType: .openCode,
            parts: [MessagePart(id: "\(id)/note", kind: .note(TranscriptNote(subject)))],
            createdAt: date(created),
            completedAt: optionalDate(created))
    }

    /// The provider wait an unfinished answer is in, where the server recorded one.
    static func retry(_ record: OC2Retry) -> TurnRetry {
        TurnRetry(
            attempt: record.attempt ?? 1,
            reason: record.error?.message ?? record.error?.type ?? "",
            nextAttemptAt: optionalDate(record.at))
    }

    /// The wait the transcript leaves the conversation in: the newest answer's, while it is still
    /// unfinished. A retry recorded on an answer that later finished is history, not a wait.
    static func pendingRetry(_ messages: [OC2Message]) -> TurnRetry? {
        guard let last = messages.last(where: { $0.type == "assistant" }),
            last.time?.completed == nil, let record = last.retry
        else { return nil }
        return retry(record)
    }

    /// The turn a server left unfinished, read from its records: an answer that never completed,
    /// a step that ended calling tools with nothing after it, or a prompt nothing ever answered,
    /// with no idle marker closing the turn and no word from this app that the person let it go.
    /// Only a server with nothing open for the session can have left one, which the caller checks.
    static func cutOffTurn(_ records: [OC2Message], detectedAt: Date) -> TurnInterruption? {
        guard let end = records.lastIndex(where: { turnRecords.contains($0.type) }) else { return nil }
        let last = records[end]
        switch last.type {
        case "assistant":
            guard last.error == nil else { return nil }
            if last.time?.completed != nil, last.finish != "tool-calls" { return nil }
        case "user":
            break
        default:
            return nil
        }
        let after = records[records.index(after: end)...]
        guard !after.contains(where: isDismissal) else { return nil }
        guard let start = records[...end].lastIndex(where: { $0.type == "user" }) else { return nil }
        let prompt = records[start]
        return TurnInterruption(
            turnID: last.id,
            prompt: prompt.text ?? "",
            startedAt: date(prompt.time?.created),
            detectedAt: detectedAt,
            progress: TurnInterruption.Progress(reading: transcript(Array(records[start...end]))),
            holdsUnattendedWork: false)
    }

    private static let turnRecords: Set<String> = ["user", "assistant", "idle"]

    /// The line this app writes when somebody lets an interrupted turn go: hidden from the reader,
    /// telling the model what happened, and marking the turn as settled for every device.
    static func isDismissal(_ record: OC2Message) -> Bool {
        record.type == "synthetic" && isDismissal(metadata: record.metadata)
    }

    /// The same line while it is still waiting in the session's inbox for the next turn, which is
    /// where it sits until something runs: written without waking the session, it is delivered
    /// only when the next prompt is.
    static func isDismissal(_ item: OC2InboxItem) -> Bool {
        item.type == "synthetic" && isDismissal(metadata: item.payload?["metadata"])
    }

    private static func isDismissal(metadata: JSONValue?) -> Bool {
        metadata?[dismissalKey]?.stringValue == dismissalValue
    }

    static let dismissalKey = "interruption"
    static let dismissalValue = "dismissed"

    /// The newest moment anything in the records says was written, which is how long a turn has
    /// been silent: a turn another process is still writing moves this, and one whose process is
    /// gone never will again.
    static func lastWritten(_ records: [OC2Message], session: OC2Session?) -> Date {
        var newest = session?.time?.updated ?? 0
        for record in records.suffix(8) {
            let stamps = [record.time?.created, record.time?.streamed, record.time?.completed]
            newest = max(newest, stamps.compactMap { $0 }.max() ?? 0)
            for content in record.content ?? [] {
                let ran = [content.time?.created, content.time?.ran, content.time?.completed]
                newest = max(newest, ran.compactMap { $0 }.max() ?? 0)
            }
        }
        return date(newest)
    }

    static func revert(_ record: OC2Revert) -> SessionRevert {
        SessionRevert(
            messageID: record.messageID,
            files: (record.files ?? []).map { file in
                SessionRevert.File(
                    path: file.file,
                    change: SessionRevert.File.Change(rawValue: file.status ?? "") ?? .modified,
                    additions: file.additions ?? 0,
                    deletions: file.deletions ?? 0,
                    patch: file.patch)
            })
    }

    /// When the transcript itself says a compaction is still running, and since when. The record
    /// is written `running` the moment the summary begins and rewritten when it ends, so a running
    /// record that nothing has followed is the live compaction — unless it is older than a
    /// compaction can plausibly take, in which case it is a record something failed to close.
    static func compactionInFlight(_ messages: [OC2Message], now: Date = Date()) -> Date? {
        guard let last = messages.last(where: { $0.type == "compaction" }),
            last.status == "running"
        else { return nil }
        guard messages.last?.id == last.id else { return nil }
        let startedAt = date(last.time?.created)
        guard now.timeIntervalSince(startedAt) < staleMarker else { return nil }
        return startedAt
    }

    static let staleMarker: TimeInterval = 30 * 60

    static func errorMessage(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let message = value["message"]?.stringValue, !message.isEmpty { return message }
        if let type = value["type"]?.stringValue, !type.isEmpty { return type }
        if case .string(let string) = value { return string }
        return nil
    }
}
