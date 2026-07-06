import AgentCore
import Foundation

public enum ClaudeCodeEventDecoder {
    public static func decode(_ event: SSEvent) -> BackendEvent? {
        guard let data = event.data.data(using: .utf8) else { return nil }

        switch event.type {
        case "message_update":
            guard let update = try? JSONCoding.decoder.decode(AAMessageUpdate.self, from: data)
            else {
                return nil
            }
            return .messageUpserted(ClaudeCodeMapping.update(update), replaceParts: true)

        case "status_change":
            guard let change = try? JSONCoding.decoder.decode(AAStatusChange.self, from: data)
            else {
                return nil
            }
            return .status(ClaudeCodeMapping.status(change.status))

        case "agent_error":
            let message =
                (try? JSONCoding.decoder.decode(AAError.self, from: data))?.message ?? "agent error"
            return .failure(BackendFailure(message: message))

        default:
            return .unknown(type: event.type ?? "")
        }
    }
}
