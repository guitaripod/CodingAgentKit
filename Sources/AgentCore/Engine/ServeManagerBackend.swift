import Foundation

/// A server a client can put its own supervisor under, so everything that needs the machine —
/// the restart command, the catalog refresher — is there without a terminal ever being opened on it.
///
/// A server set up by hand answers every ask except the restart, which is the one ask that cannot
/// be answered remotely any other way. The install is one press and is idempotent: files the setup
/// wrote carry a marker and are only ever rewritten by the setup itself.
public protocol ServeManagerBackend: CodingAgentBackend {
    func installServeManager() async throws
}
