import Foundation

/// A server a client can ask to start over.
///
/// The machine running the agent is usually one the person holding the phone cannot open a terminal
/// on, so anything that only a restart fixes — a model list resolved days ago, a config edited
/// since, a plugin that was installed after the process began — is otherwise out of reach from the
/// only device that is actually present. This is the way back to it.
///
/// Asking is the whole of it. The server stops answering a moment later and the connection the ask
/// went over dies with it, so there is nothing to await: a caller hands the request over and lets
/// the ordinary reconnect say when the machine is back. A server that cannot restart itself throws
/// ``AgentError/unsupported(_:)`` rather than leaving a client waiting for a return that is not
/// coming.
public protocol RestartableBackend: CodingAgentBackend {
    func restart() async throws
}
