import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The shells a bridge holds. Every route answers 404 on a bridge built before them, which reads
/// as an empty list here and as a terminal that is gone everywhere else.
extension ClaudeCodeBackend: TerminalHostingBackend {
    public func terminals() async throws -> [TerminalInfo] {
        do {
            let data = try await http.send(builder.request(.get, "/terminals"))
            return try BridgeCoding.decoder.decode([TerminalInfo].self, from: data)
        } catch let error as AgentError {
            if case .http(let status, _) = error, status == 404 { return [] }
            throw error
        }
    }

    public func openTerminal(_ request: TerminalOpenRequest) async throws -> TerminalInfo {
        let body = try JSONEncoder().encode(request)
        let data = try await http.send(builder.request(.post, "/terminals", body: body))
        return try BridgeCoding.decoder.decode(TerminalInfo.self, from: data)
    }

    public func terminal(_ id: String) async throws -> TerminalInfo? {
        do {
            let data = try await http.send(builder.request(.get, "/terminals/\(id)"))
            return try BridgeCoding.decoder.decode(TerminalInfo.self, from: data)
        } catch let error as AgentError {
            if case .http(let status, _) = error, status == 404 { return nil }
            throw error
        }
    }

    public func terminalFrames(_ id: String, from offset: UInt64?) -> AsyncThrowingStream<TerminalFrame, Error> {
        let query = offset.map { [URLQueryItem(name: "from", value: String($0))] } ?? []
        let request: URLRequest
        do {
            request = try builder.request(.get, "/terminals/\(id)/output", query: query)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let chunks = http.byteStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var reader = TerminalFrameReader()
                do {
                    for try await chunk in chunks {
                        for frame in try reader.read(chunk) { continuation.yield(frame) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func sendTerminalInput(_ id: String, bytes: Data) async throws {
        var request = try builder.request(.post, "/terminals/\(id)/input", body: bytes)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await http.send(request)
    }

    public func resizeTerminal(_ id: String, cols: Int, rows: Int) async throws {
        let body = try JSONEncoder().encode(TerminalResizeRequest(cols: cols, rows: rows))
        _ = try await http.send(builder.request(.post, "/terminals/\(id)/resize", body: body))
    }

    public func closeTerminal(_ id: String) async throws {
        do {
            _ = try await http.send(builder.request(.delete, "/terminals/\(id)"))
        } catch let error as AgentError {
            if case .http(let status, _) = error, status == 404 { return }
            throw error
        }
    }
}
