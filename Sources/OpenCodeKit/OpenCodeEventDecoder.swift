import AgentCore
import Foundation

public enum OpenCodeEventDecoder {
    struct Envelope: Decodable {
        let type: String
        let properties: JSONValue?
    }

    public static func decode(_ event: SSEvent, sessionID: String) -> BackendEvent? {
        guard let data = event.data.data(using: .utf8),
            let envelope = try? JSONCoding.decoder.decode(Envelope.self, from: data)
        else { return nil }

        let properties = envelope.properties
        if let eventSession = properties?["sessionID"]?.stringValue, eventSession != sessionID {
            return nil
        }

        switch envelope.type {
        case "message.updated":
            guard let info = properties?["info"], let message = message(from: info) else {
                return nil
            }
            return .messageUpserted(message, replaceParts: false)

        case "message.removed":
            guard let messageID = properties?["messageID"]?.stringValue else { return nil }
            return .messageRemoved(messageID: messageID)

        case "message.part.updated":
            guard let value = properties?["part"], let part = part(from: value) else { return nil }
            return .partUpserted(messageID: part.messageID, OpenCodeMapping.part(part))

        case "message.part.removed":
            guard let messageID = properties?["messageID"]?.stringValue,
                let partID = properties?["partID"]?.stringValue
            else { return nil }
            return .partRemoved(messageID: messageID, partID: partID)

        case "message.part.delta":
            guard let messageID = properties?["messageID"]?.stringValue,
                let partID = properties?["partID"]?.stringValue,
                let delta = properties?["delta"]?.stringValue
            else { return nil }
            let field = properties?["field"]?.stringValue
            guard field == nil || field == "text" else { return nil }
            return .partTextDelta(messageID: messageID, partID: partID, delta: delta)

        case "session.idle":
            return .status(.idle)

        case "session.error":
            let message =
                properties?["error"].flatMap(OpenCodeMapping.errorMessage) ?? "session error"
            return .failure(BackendFailure(message: message))

        case "permission.asked":
            guard let id = properties?["id"]?.stringValue else { return nil }
            let tool = properties?["tool"]?.stringValue
            return .permission(
                PermissionRequest(
                    id: id,
                    sessionID: properties?["sessionID"]?.stringValue ?? sessionID,
                    title: tool,
                    toolName: tool
                ))

        default:
            return .unknown(type: envelope.type)
        }
    }

    private static func message(from value: JSONValue) -> ChatMessage? {
        guard let data = try? JSONCoding.encoder.encode(value),
            let message = try? JSONCoding.decoder.decode(OCMessage.self, from: data)
        else { return nil }
        return OpenCodeMapping.shell(message)
    }

    private static func part(from value: JSONValue) -> OCPart? {
        guard let data = try? JSONCoding.encoder.encode(value) else { return nil }
        return try? JSONCoding.decoder.decode(OCPart.self, from: data)
    }
}
