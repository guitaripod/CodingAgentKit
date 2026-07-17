import Foundation

public enum AgentError: Error, Sendable, Equatable {
    case http(status: Int, body: String)
    case decoding(String)
    case invalidURL(String)
    case unsupported(String)
    case server(String)
    case connection(String)
}

extension AgentError {
    /// Whether reattempting the same request could plausibly succeed. Permanent HTTP failures —
    /// authentication (401), authorization (403), a missing route or session (404), and other
    /// client-side (4xx) rejections — keep failing identically, so a reconnect loop must surface a
    /// terminal state instead of retrying them forever. Transport failures, transient server
    /// errors (5xx), and the retry-friendly 4xx codes (408 Request Timeout, 425 Too Early, 429 Too
    /// Many Requests) stay retryable. Structural client-side faults (bad URL, decode failure,
    /// unsupported feature) reproduce identically and are never retryable.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _):
            return Self.isRetryableHTTPStatus(status)
        case .connection, .server:
            return true
        case .decoding, .invalidURL, .unsupported:
            return false
        }
    }

    private static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 425, 429:
            return true
        case 400..<500:
            return false
        default:
            return true
        }
    }
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if let data = body.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                let message = object["error"], !message.isEmpty
            {
                return message
            }
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
