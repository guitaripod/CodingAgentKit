import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

final class DroppingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                userInfo: [
                    NSLocalizedDescriptionKey: "The network connection was lost.",
                    "_kCFStreamErrorCodeKey": -4,
                ]))
    }

    override func stopLoading() {}
}

@Suite struct TransportWordsTests {
    @Test func aDroppedSendSaysSoInASentenceAndNeverInAnErrorDump() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DroppingURLProtocol.self]
        let client = HTTPClient(session: URLSession(configuration: configuration))
        var request = URLRequest(url: URL(string: "http://100.64.0.1:4099/sessions/a/message")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        do {
            try await client.send(request)
            Issue.record("a dropped connection must throw")
        } catch let error as AgentError {
            #expect(error == .connection("The connection to the server dropped."))
            let shown = error.errorDescription ?? ""
            #expect(!shown.contains("Error Domain"))
            #expect(!shown.contains("Code="))
            #expect(!shown.contains("_kCF"))
            #expect(error.isRetryable)
        }
    }

    @Test func everyCommonTransportFailureHasItsOwnSentence() {
        let cases: [(URLError.Code, String)] = [
            (.networkConnectionLost, "The connection to the server dropped."),
            (.timedOut, "The server took too long to answer."),
            (.notConnectedToInternet, "This device is offline."),
            (.cannotConnectToHost, "Nothing is answering at that address."),
            (.cannotFindHost, "That address could not be found."),
            (.dnsLookupFailed, "That address could not be found."),
            (.secureConnectionFailed, "A secure connection to the server could not be made."),
            (.badServerResponse, "The server's answer could not be read."),
            (.unknown, "The connection to the server failed."),
            (.callIsActive, "The connection to the server failed."),
        ]
        for (code, sentence) in cases {
            #expect(TransportWords.sentence(for: URLError(code)) == sentence)
        }
    }

    @Test func aBridgedNSErrorReadsTheSameAsTheURLErrorItCameFrom() {
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(TransportWords.sentence(for: bridged) == "The server took too long to answer.")
    }

    @Test func somethingThatIsNotATransportErrorStillGetsASentence() {
        struct Stranger: Error {}
        #expect(TransportWords.sentence(for: Stranger()) == "The connection to the server failed.")
    }
}
