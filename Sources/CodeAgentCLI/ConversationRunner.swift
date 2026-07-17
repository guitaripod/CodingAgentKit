import CodingAgentKit
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

enum ConversationRunner {
    static func run(
        backend: any CodingAgentBackend,
        sessionID: String,
        send: String?,
        model: ModelSelection?,
        attachments: [PromptAttachment] = [],
        followForever: Bool
    ) async throws {
        var reducer = MessageReducer(agentType: backend.agentType)
        var shownText: [String: Int] = [:]
        var shownTools: Set<String> = []
        var sawRunning = false

        let events = backend.events(for: sessionID)
        let sendTask = makeSendTask(
            backend: backend, sessionID: sessionID, send: send, model: model,
            attachments: attachments)
        defer { sendTask?.cancel() }

        for try await event in events {
            reducer.apply(event)
            render(reducer.snapshot, shownText: &shownText, shownTools: &shownTools)

            switch event {
            case .failure(let failure):
                FileHandle.standardError.write(Data("\n[error] \(failure.message)\n".utf8))
            case .status(.running):
                sawRunning = true
            case .status(.idle), .status(.stable):
                if !followForever,
                    await settleEndsRun(send: send, sawRunning: sawRunning, sendTask: sendTask)
                {
                    print("")
                    return
                }
            default:
                break
            }
        }
        _ = await sendTask?.value
        print("")
    }

    /// Delivers the `--send` prompt after a short delay that lets the event stream
    /// attach first, reporting whether the prompt reached the backend. Kept as a
    /// structured handle so the run can await delivery before exiting (the prompt
    /// is never silently dropped and send errors always surface) and cancel it if
    /// the stream fails mid-flight.
    private static func makeSendTask(
        backend: any CodingAgentBackend,
        sessionID: String,
        send: String?,
        model: ModelSelection?,
        attachments: [PromptAttachment]
    ) -> Task<Bool, Never>? {
        guard let text = send else { return nil }
        let prompt = SendPrompt(text: text, model: model, attachments: attachments)
        return Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await backend.send(prompt, to: sessionID)
                return true
            } catch is CancellationError {
                return false
            } catch {
                FileHandle.standardError.write(Data("\n[error] send failed: \(error)\n".utf8))
                return false
            }
        }
    }

    /// Whether an idle/stable event should end a non-follow run. With no pending
    /// send, a settled turn is the end. With one, the run must first guarantee the
    /// prompt was delivered: a settle seen after the agent started (`sawRunning`)
    /// is the real end, while an earlier settle only ends the run if the prompt
    /// could not be delivered — otherwise the response is still on its way.
    private static func settleEndsRun(
        send: String?, sawRunning: Bool, sendTask: Task<Bool, Never>?
    ) async -> Bool {
        guard send != nil, let sendTask else { return true }
        if sawRunning {
            _ = await sendTask.value
            return true
        }
        let delivered = await sendTask.value
        return !delivered
    }

    private static func render(
        _ snapshot: [ChatMessage], shownText: inout [String: Int], shownTools: inout Set<String>
    ) {
        for message in snapshot where message.role == .assistant {
            for part in message.parts {
                let key = "\(message.id):\(part.id)"
                switch part.kind {
                case .text(let text), .reasoning(let text):
                    let already = shownText[key] ?? 0
                    if text.count > already {
                        let start = text.index(text.startIndex, offsetBy: already)
                        print(String(text[start...]), terminator: "")
                        shownText[key] = text.count
                        flush()
                    }
                case .tool(let tool):
                    let toolKey = "\(key):\(tool.status.rawValue)"
                    if !shownTools.contains(toolKey) {
                        shownTools.insert(toolKey)
                        let title = tool.title.map { " (\($0))" } ?? ""
                        print("\n[tool] \(tool.name) — \(tool.status.rawValue)\(title)")
                        flush()
                    }
                case .file, .unknown:
                    break
                }
            }
        }
    }

    private static func flush() {
        fflush(nil)
    }
}
