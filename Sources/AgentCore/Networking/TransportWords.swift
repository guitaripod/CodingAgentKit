import Foundation
import Logging

#if canImport(FoundationNetworking)
    import AsyncHTTPClient
    import FoundationNetworking
    import NIOCore
#endif

/// A transport failure as one sentence a person can read.
///
/// `String(describing:)` of a `URLError` is a paragraph of `Error Domain=NSURLErrorDomain
/// Code=-1005 … UserInfo={_kCFStreamErrorCodeKey=-4, …}`, and every screen that showed
/// ``AgentError/connection(_:)`` showed that paragraph: a send that did not go, a server that did
/// not answer a probe, a stream that dropped. The sentence goes into the error; the paragraph goes
/// to the log, where it is still useful.
public enum TransportWords {
    public static func sentence(for error: any Error) -> String {
        if let urlError = error as? URLError { return sentence(for: urlError.code) }
        #if canImport(FoundationNetworking)
            if let sentence = linuxSentence(for: error) { return sentence }
        #endif
        let nsError = error as NSError
        let code: URLError.Code? = URLError.Code(rawValue: nsError.code)
        if nsError.domain == NSURLErrorDomain, let code { return sentence(for: code) }
        return AgentText.string("The connection to the server failed.")
    }

    static func sentence(for code: URLError.Code) -> String {
        switch code {
        case .networkConnectionLost:
            return AgentText.string("The connection to the server dropped.")
        case .timedOut:
            return AgentText.string("The server took too long to answer.")
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return AgentText.string("This device is offline.")
        case .cannotConnectToHost:
            return AgentText.string("Nothing is answering at that address.")
        case .cannotFindHost, .dnsLookupFailed:
            return AgentText.string("That address could not be found.")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            return AgentText.string("A secure connection to the server could not be made.")
        case .badServerResponse, .cannotParseResponse, .zeroByteResource,
            .cannotDecodeRawData, .cannotDecodeContentData:
            return AgentText.string("The server's answer could not be read.")
        default:
            return AgentText.string("The connection to the server failed.")
        }
    }

    #if canImport(FoundationNetworking)
        /// AsyncHTTPClient and SwiftNIO, which carry streams on Linux, throw their own types. A
        /// refused or reset socket arrives as an `IOError`, either thrown directly or held inside
        /// NIOPosix's `NIOConnectionError`, which this target does not link, so it is found by
        /// looking inside whatever was thrown.
        private static func linuxSentence(for error: any Error) -> String? {
            if let client = error as? HTTPClientError {
                switch client {
                case .readTimeout, .connectTimeout, .deadlineExceeded:
                    return sentence(for: .timedOut)
                case .remoteConnectionClosed:
                    return sentence(for: .networkConnectionLost)
                default:
                    break
                }
            }
            if case ChannelError.connectTimeout = error { return sentence(for: .timedOut) }
            if case ChannelError.ioOnClosedChannel = error {
                return sentence(for: .networkConnectionLost)
            }
            if let io = socketError(in: error, depth: 3) { return sentence(errno: io.errnoCode) }
            return nil
        }

        private static func socketError(in value: Any, depth: Int) -> IOError? {
            if let io = value as? IOError { return io }
            guard depth > 0 else { return nil }
            for child in Mirror(reflecting: value).children {
                if let io = socketError(in: child.value, depth: depth - 1) { return io }
            }
            return nil
        }

        private static func sentence(errno code: Int32) -> String? {
            switch code {
            case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH: return sentence(for: .cannotConnectToHost)
            case ECONNRESET, EPIPE, ECONNABORTED: return sentence(for: .networkConnectionLost)
            case ETIMEDOUT: return sentence(for: .timedOut)
            case ENETDOWN: return sentence(for: .notConnectedToInternet)
            default: return nil
            }
        }
    #endif
}

extension AgentError {
    /// A transport failure as ``connection(_:)`` carrying its sentence, with the error itself
    /// written to the log.
    static func transport(_ error: any Error) -> AgentError {
        TransportWords.log.debug("transport failure: \(String(describing: error))")
        return .connection(TransportWords.sentence(for: error))
    }
}

extension TransportWords {
    fileprivate static let log = AgentLog.logger("http")
}
