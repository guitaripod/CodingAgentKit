import Foundation
import Testing

@testable import AgentCore

/// Reading a cut-off turn off a transcript, for the servers that cannot report their own. The
/// whole point is what it refuses to call dead: a turn that moved by one character between two
/// readings is a turn that is merely slow, and the difference is the only thing standing between
/// a useful card and one that interrupts working conversations.
@Suite struct CutOffTurnTests {
    private func message(
        id: String, role: MessageRole, text: String, completed: Bool = false,
        tools: [ToolCall] = []
    ) -> ChatMessage {
        var parts = [MessagePart(id: "\(id)-t", kind: .text(text))]
        parts += tools.map { MessagePart(id: $0.id, kind: .tool($0)) }
        return ChatMessage(
            id: id, role: role, agentType: .openCode, parts: parts,
            createdAt: Date(timeIntervalSince1970: 1_000),
            completedAt: completed ? Date(timeIntervalSince1970: 1_010) : nil,
            isStreaming: !completed)
    }

    @Test func anUnfinishedAnswerIsTheOnlyThingItReads() {
        let asked = message(id: "u1", role: .user, text: "port the parser", completed: true)
        let answered = message(id: "a1", role: .assistant, text: "done", completed: true)
        #expect(CutOffTurn.read([asked, answered], detectedAt: Date()) == nil)
        #expect(CutOffTurn.fingerprint([asked, answered]) == nil)

        let hanging = message(id: "a2", role: .assistant, text: "starting")
        let cutOff = CutOffTurn.read([asked, hanging], detectedAt: Date())
        #expect(cutOff?.turnID == "a2")
        #expect(cutOff?.prompt == "port the parser")
    }

    @Test func aTurnStillWritingMovesItsFingerprint() {
        let asked = message(id: "u1", role: .user, text: "go", completed: true)
        let early = message(id: "a1", role: .assistant, text: "reading")
        let later = message(id: "a1", role: .assistant, text: "reading the file")
        #expect(CutOffTurn.fingerprint([asked, early]) != CutOffTurn.fingerprint([asked, later]))
        #expect(CutOffTurn.fingerprint([asked, early]) == CutOffTurn.fingerprint([asked, early]))
    }

    @Test func aToolSettlingMovesItToo() {
        let asked = message(id: "u1", role: .user, text: "go", completed: true)
        let running = message(
            id: "a1", role: .assistant, text: "",
            tools: [ToolCall(id: "t1", name: "bash", status: .running)])
        let settled = message(
            id: "a1", role: .assistant, text: "",
            tools: [ToolCall(id: "t1", name: "bash", status: .completed)])
        #expect(CutOffTurn.fingerprint([asked, running]) != CutOffTurn.fingerprint([asked, settled]))
    }

    @Test func whatTheTurnGotThroughIsReadFromItsOwnParts() {
        let asked = message(id: "u1", role: .user, text: "fix it", completed: true)
        let hanging = message(
            id: "a1", role: .assistant, text: "I will start with the parser",
            tools: [
                ToolCall(
                    id: "t1", name: "bash", status: .completed,
                    input: .object(["command": .string("swift build")])),
                ToolCall(
                    id: "t2", name: "edit", status: .running,
                    input: .object(["file_path": .string("/tmp/Parser.swift")])),
            ])
        let cutOff = CutOffTurn.read([asked, hanging], detectedAt: Date())
        #expect(cutOff?.progress.toolCount == 2)
        #expect(cutOff?.progress.commands == ["swift build"])
        #expect(cutOff?.progress.filesTouched == ["/tmp/Parser.swift"])
        #expect(cutOff?.progress.partialAnswer == "I will start with the parser")
        #expect(cutOff?.didAnything == true)
    }

    @Test func aTurnTheServerFailedIsNotAnInterruption() {
        let asked = message(id: "u1", role: .user, text: "go", completed: true)
        var failed = message(id: "a1", role: .assistant, text: "")
        failed.error = "rate limited"
        #expect(CutOffTurn.read([asked, failed], detectedAt: Date()) == nil)
    }
}
