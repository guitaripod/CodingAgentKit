import Foundation
import Testing

@testable import AgentCore

private func call(
    _ name: String, input: [String: JSONValue]? = nil, output: String? = nil
) -> ToolCall {
    ToolCall(
        id: "t1", name: name, status: .completed,
        input: input.map { JSONValue.object($0) }, output: output)
}

@Suite struct ToolCallSummaryClassifyTests {
    @Test func namesMapToKinds() {
        let cases: [(String, ToolCallSummary.Kind)] = [
            ("Bash", .shell),
            ("Edit", .fileEdit),
            ("MultiEdit", .fileEdit),
            ("NotebookEdit", .fileEdit),
            ("Write", .fileWrite),
            ("Read", .fileRead),
            ("Grep", .fileSearch),
            ("Glob", .fileSearch),
            ("ls", .fileSearch),
            ("ToolSearch", .fileSearch),
            ("WebSearch", .webSearch),
            ("WebFetch", .webFetch),
            ("TodoWrite", .taskTracking),
            ("TaskCreate", .taskTracking),
            ("TaskUpdate", .taskTracking),
            ("Task", .subagent),
            ("Agent", .subagent),
            ("Workflow", .workflow),
            ("Skill", .skill),
            ("mcp__appstore__list_apps", .fileSearch),
        ]
        for (name, kind) in cases {
            #expect(ToolCallSummaryBuilder.classify(name) == kind, "\(name)")
        }
    }
}

@Suite struct ToolCallSummaryContentTests {
    @Test func bashUsesDescriptionAndCommand() {
        let summary = call(
            "Bash",
            input: [
                "command": .string("ls -la ~/.steam | head -40"),
                "description": .string("List Steam dirs by recency"),
            ],
            output: "total 77236\ndrwx------ 1 marcus"
        ).summary
        #expect(summary.title == "List Steam dirs by recency")
        #expect(summary.command == "ls -la ~/.steam | head -40")
        #expect(summary.displayOutput?.hasPrefix("total 77236") == true)
    }

    @Test func bashWithoutDescriptionFallsBackToCommandFirstLine() {
        let summary = call(
            "Bash", input: ["command": .string("swift build\nswift test")]
        ).summary
        #expect(summary.title == "swift build")
    }

    @Test func readShowsBasenameDirectoryAndLineCount() {
        let summary = call(
            "Read",
            input: ["file_path": .string("/Users/marcus/Dev/App/AppCoordinator.swift")],
            output: "1\timport UIKit\n2\tfinal class AppCoordinator {\n3\t}"
        ).summary
        #expect(summary.title == "AppCoordinator.swift")
        #expect(summary.detail == "/Users/marcus/Dev/App")
        #expect(summary.metric == "3 lines")
        #expect(summary.displayOutput == nil)
        #expect(summary.filePath == "/Users/marcus/Dev/App/AppCoordinator.swift")
    }

    @Test func editComputesDiffStatsAndHidesOutput() {
        let summary = call(
            "Edit",
            input: [
                "file_path": .string("/tmp/a/b.swift"),
                "old_string": .string("let a = 1"),
                "new_string": .string("let a = 1\nlet b = 2"),
            ],
            output: "The file /tmp/a/b.swift has been updated successfully."
        ).summary
        #expect(summary.title == "b.swift")
        #expect(summary.diffStats == ToolCallSummary.DiffStats(added: 2, removed: 1))
        #expect(summary.displayOutput == nil)
    }

    @Test func writeCountsContentAsAdded() {
        let summary = call(
            "Write",
            input: [
                "file_path": .string("/tmp/new.txt"),
                "content": .string("one\ntwo\nthree"),
            ]
        ).summary
        #expect(summary.diffStats == ToolCallSummary.DiffStats(added: 3, removed: 0))
    }

    @Test func webSearchParsesLinksAndKeepsProse() {
        let output = """
            Web search results for query: "best tablet"

            Links: [{"title":"Best tablets 2026","url":"https://example.com/a"},{"title":"","url":"https://other.org/b"}]

            Here's what I found on tablets.
            """
        let summary = call(
            "WebSearch", input: ["query": .string("best tablet")], output: output
        ).summary
        #expect(summary.title == "best tablet")
        #expect(summary.links.count == 2)
        #expect(summary.links[0].title == "Best tablets 2026")
        #expect(summary.links[1].title == "other.org")
        #expect(summary.displayOutput == "Here's what I found on tablets.")
    }

    @Test func webSearchWithMangledLinksKeepsLineAsProse() {
        let output = "Links: [{\"title\":\"cut off"
        let summary = call("WebSearch", output: output).summary
        #expect(summary.links.isEmpty)
        #expect(summary.displayOutput == output)
    }

    @Test func taskToolsSummarizeSubjectAndStatus() {
        let created = call(
            "TaskCreate", input: ["subject": .string("Add SessionSeenStore")]
        ).summary
        #expect(created.title == "Add SessionSeenStore")
        let updated = call(
            "TaskUpdate",
            input: ["taskId": .string("3"), "status": .string("in_progress")]
        ).summary
        #expect(updated.title == "Task #3")
        #expect(updated.detail == "in progress")
        #expect(updated.displayOutput == nil)
    }

    @Test func subagentUsesDescriptionAndType() {
        let summary = call(
            "Task",
            input: [
                "description": .string("Audit the store"),
                "subagent_type": .string("code-reviewer"),
            ],
            output: "Findings: none"
        ).summary
        #expect(summary.title == "Audit the store")
        #expect(summary.detail == "code-reviewer")
        #expect(summary.displayOutput == "Findings: none")
    }

    @Test func workflowExtractsNameFromScript() {
        let script = "export const meta = { name: 'review-changes', description: 'x' }"
        let summary = call("Workflow", input: ["script": .string(script)]).summary
        #expect(summary.title == "review-changes")
        #expect(summary.displayOutput == nil)
    }

    @Test func readWithoutStructuredInputKeepsOutputVisible() {
        let summary = call("Read", output: "12:  .background(Color.white)").summary
        #expect(summary.title == nil)
        #expect(summary.displayOutput == "12:  .background(Color.white)")
    }

    @Test func editWithoutStructuredInputKeepsOutputVisible() {
        let summary = call("Edit", output: "-old line\n+new line").summary
        #expect(summary.diffStats == nil)
        #expect(summary.displayOutput == "-old line\n+new line")
    }

    @Test func strippedOutputRemovesHarnessMarkup() {
        let summary = call(
            "Bash", input: ["command": .string("true")],
            output: "ok\n<system-reminder>noise</system-reminder>"
        ).summary
        #expect(summary.displayOutput == "ok")
    }
}
