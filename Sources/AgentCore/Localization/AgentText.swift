import Foundation

/// The Kit's own human-facing prose — the handful of error sentences and
/// fallback titles a person reads in a client UI. Wire tokens (tool names,
/// model ids, HTTP bodies, shell output) never pass through here.
///
/// `NSLocalizedString` rather than `String(localized:)`: the latter has no
/// `bundle:` overload on Linux, where this package also builds. Lookup that
/// finds no translation returns the key, which is the English source string.
///
/// Linux never localizes, and SwiftPM's `Bundle.module` accessor there traps
/// when the resource bundle is not beside the executable, which is the case
/// for every installed binary, so Linux answers the key without touching it.
enum AgentText {
    static func string(_ key: String) -> String {
        #if os(Linux)
        return key
        #else
        return NSLocalizedString(key, bundle: .module, comment: "")
        #endif
    }

    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    static func count(_ key: String, _ value: Int) -> String {
        String.localizedStringWithFormat(string(key), value)
    }
}
