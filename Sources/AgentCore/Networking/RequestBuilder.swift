import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct RequestBuilder: Sendable {
    public let config: ServerConfig

    public init(config: ServerConfig) {
        self.config = config
    }

    public func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var base = config.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(string: base + suffix) else {
            throw AgentError.invalidURL(base + suffix)
        }
        if !query.isEmpty {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+"))
            let encoded = query.map { item in
                URLQueryItem(
                    name: item.name.addingPercentEncoding(withAllowedCharacters: allowed)
                        ?? item.name,
                    value: item.value?.addingPercentEncoding(withAllowedCharacters: allowed))
            }
            components.percentEncodedQueryItems =
                (components.percentEncodedQueryItems ?? []) + encoded
        }
        guard let resolved = components.url else {
            throw AgentError.invalidURL(base + suffix)
        }
        return resolved
    }

    public func request(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func eventStreamRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest
    {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        applyAuthorization(to: &request)
        return request
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let credentials = config.credentials else { return }
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
    }
}
