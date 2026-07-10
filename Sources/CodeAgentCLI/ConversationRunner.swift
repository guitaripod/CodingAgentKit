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
        if let text = send {
            let prompt = SendPrompt(text: text, model: model, attachments: attachments)
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                do {
                    try await backend.send(prompt, to: sessionID)
                } catch {
                    FileHandle.standardError.write(Data("\n[error] send failed: \(error)\n".utf8))
                }
            }
        }

        for try await event in events {
            reducer.apply(event)
            render(reducer.snapshot, shownText: &shownText, shownTools: &shownTools)

            switch event {
            case .failure(let failure):
                FileHandle.standardError.write(Data("\n[error] \(failure.message)\n".utf8))
            case .status(.running):
                sawRunning = true
            case .status(.idle) where !followForever:
                print("")
                return
            case .status(.stable) where !followForever && (send == nil || sawRunning):
                print("")
                return
            default:
                break
            }
        }
        print("")
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
