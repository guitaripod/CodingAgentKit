import Foundation

public enum AgentError: Error, Sendable, Equatable {
    case http(status: Int, body: String)
    case decoding(String)
    case invalidURL(String)
    case unsupported(String)
    case server(String)
    case connection(String)
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .decoding(let detail): return "Decoding failed: \(detail)"
        case .invalidURL(let detail): return "Invalid URL: \(detail)"
        case .unsupported(let feature): return "Unsupported by this backend: \(feature)"
        case .server(let detail): return "Server error: \(detail)"
        case .connection(let detail): return "Connection error: \(detail)"
        }
    }
}
