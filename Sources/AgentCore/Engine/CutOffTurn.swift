import Foundation

/// A turn read as cut off from the transcript alone, for servers that cannot say so themselves.
///
/// claude-bridge notices its own death: it comes back up, finds the turn it was in the middle of,
/// and reports it on a route. opencode records nothing to tell them apart — a killed turn and a
/// running one leave the same message behind, created, with no completion and no error on it. So
/// the reading has to come from the only party that watched both sides of the gap, which is this
/// client.
///
/// The evidence is deliberately narrow. Nothing here is a timeout on an answer: a slow model still
/// arrives in pieces, and any piece at all moves the fingerprint and disqualifies the reading. What
/// it takes is a turn that did not move by a single character across a whole stretch in which the
/// transport was up and nothing was said — which is what a machine that died under a turn leaves,
/// and what a machine still working on one never does.
enum CutOffTurn {
    /// Everything about an unfinished turn that changes while it is still being written. Two equal
    /// readings either side of a quiet stretch are the whole case for calling it dead.
    struct Fingerprint: Equatable {
        let messageID: String
        let parts: Int
        let characters: Int
        let settledTools: Int
    }

    static func fingerprint(_ messages: [ChatMessage]) -> Fingerprint? {
        guard let last = unfinishedTurn(in: messages) else { return nil }
        var characters = 0
        var settledTools = 0
        for part in last.parts {
            characters += part.text?.count ?? 0
            if case .tool(let call) = part.kind {
                characters += call.output?.count ?? 0
                if call.status == .completed || call.status == .error { settledTools += 1 }
            }
        }
        return Fingerprint(
            messageID: last.id, parts: last.parts.count, characters: characters,
            settledTools: settledTools)
    }

    static func read(_ messages: [ChatMessage], detectedAt: Date) -> TurnInterruption? {
        guard let last = unfinishedTurn(in: messages) else { return nil }
        let asked = messages.last { $0.role == .user }
        return TurnInterruption(
            turnID: last.id,
            prompt: asked?.parts.compactMap(\.text).joined(separator: "\n") ?? "",
            startedAt: last.createdAt,
            detectedAt: detectedAt,
            progress: progress(of: last))
    }

    private static func unfinishedTurn(in messages: [ChatMessage]) -> ChatMessage? {
        guard let last = messages.last, last.role == .assistant, last.completedAt == nil,
            last.error == nil
        else { return nil }
        return last
    }

    /// What the turn had already done, taken from its own parts rather than from anything it said
    /// about itself — which is the only account available once the process that was writing it is
    /// gone.
    private static func progress(of message: ChatMessage) -> TurnInterruption.Progress {
        var toolCount = 0
        var lastTool: String?
        var files: [String] = []
        var commands: [String] = []
        var answer = ""
        for part in message.parts {
            switch part.kind {
            case .text(let value):
                answer += value
            case .tool(let call):
                toolCount += 1
                let summary = ToolCallSummaryBuilder.build(call)
                lastTool = summary.title ?? call.name
                if let path = summary.filePath, !files.contains(path) { files.append(path) }
                if let command = summary.command, !commands.contains(command) {
                    commands.append(command)
                }
            default:
                continue
            }
        }
        let partial = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return TurnInterruption.Progress(
            toolCount: toolCount, lastTool: lastTool, filesTouched: files, commands: commands,
            partialAnswer: partial.isEmpty ? nil : partial)
    }
}
