import AgentCore
import Foundation

/// opencode 2's inbox read as the Kit's shared queue: what a prompt sent behind a running turn
/// waits in until the session takes it up.
extension OpenCodeV2Mapping {
    /// A prompt waiting in the inbox as a queued prompt. Only what a person typed is a queue
    /// item; the lines the server writes for the model alone (`synthetic`) wait in the same inbox
    /// and are nobody's to edit or cancel.
    static func queued(
        inboxID: String, type: String, payload: JSONValue?, created: Double?
    ) -> QueuedPrompt? {
        guard type == "user", let payload else { return nil }
        let files = payload["files"].flatMap { value -> [JSONValue]? in
            if case .array(let items) = value { return items }
            return nil
        }
        return QueuedPrompt(
            id: inboxID, text: payload["text"]?.stringValue ?? "", kind: .prompt,
            attachments: (files ?? []).compactMap(queuedAttachment),
            createdAt: created.map { date($0) } ?? .distantPast)
    }

    static func queued(_ item: OC2InboxItem) -> QueuedPrompt? {
        queued(
            inboxID: item.id, type: item.type, payload: item.payload, created: item.time?.created)
    }

    static func queue(_ items: [OC2InboxItem]) -> QueueSnapshot {
        QueueSnapshot(items: items.compactMap(queued))
    }

    /// A file carries its bytes inline as base64 or a uri to read them from; the size is the
    /// bytes when they are here and unknown otherwise.
    private static func queuedAttachment(_ file: JSONValue) -> QueuedAttachment? {
        guard let mime = file["mime"]?.stringValue else { return nil }
        return QueuedAttachment(
            mime: mime, filename: displayName(file["name"]?.stringValue),
            size: file["data"]?.stringValue.map(decodedSize))
    }

    private static func decodedSize(base64 text: String) -> Int {
        let padding = text.suffix(2).filter { $0 == "=" }.count
        return max(0, text.count * 3 / 4 - padding)
    }
}
