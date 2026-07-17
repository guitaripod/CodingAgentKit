public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value as an `Int64` when it is exactly an integer — either an
    /// `.integer` or a `.number` with no fractional part that fits `Int64`.
    public var intValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    /// The value as a `Double`, widening an `.integer` (which may lose
    /// precision above 2^53, the inherent limit of `Double`).
    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    public var compactDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return String(value)
        case .integer(let value): return String(value)
        case .number(let value):
            if value.rounded() == value, let integer = Int64(exactly: value) {
                return String(integer)
            }
            return String(value)
        case .string(let value): return value
        case .array(let value):
            return "[" + value.map(\.compactDescription).joined(separator: ", ") + "]"
        case .object(let value):
            return "{" + value.map { "\($0): \($1.compactDescription)" }.joined(separator: ", ")
                + "}"
        }
    }
}
