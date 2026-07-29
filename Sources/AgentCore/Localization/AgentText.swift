import Foundation

/// The Kit's own human-facing prose — the handful of error sentences and
/// fallback titles a person reads in a client UI. Wire tokens (tool names,
/// model ids, HTTP bodies, shell output) never pass through here.
///
/// `NSLocalizedString` rather than `String(localized:)`: the latter has no
/// `bundle:` overload on Linux, where this package also builds. Where the
/// resource bundle is not compiled — SwiftPM on Linux, `swift test` — lookup
/// returns the key, which is the English source string.
enum AgentText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    static func count(_ key: String, _ value: Int) -> String {
        String.localizedStringWithFormat(string(key), value)
    }
}
