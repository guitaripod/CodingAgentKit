import Foundation

public struct SSEvent: Sendable, Hashable {
    public let id: String?
    public let type: String?
    public let data: String

    public init(id: String?, type: String?, data: String) {
        self.id = id
        self.type = type
        self.data = data
    }
}

extension SSEvent {
    /// Whether `needle` appears anywhere in the event's data, compared byte for byte.
    ///
    /// A server that streams every session's tokens on one connection hands each listener
    /// hundreds of events a second it has no use for, and the cheapest way to pass one over is to
    /// see that the id it would have to carry is not in it at all. The standard library's
    /// substring search walks grapheme clusters, which on an iPhone XS cost more than the rest
    /// of the hub's delivery together.
    public func mentions(_ needle: String) -> Bool {
        var haystack = data
        var pattern = needle
        return haystack.withUTF8 { text in
            pattern.withUTF8 { word in
                guard !word.isEmpty else { return true }
                guard word.count <= text.count, let base = text.baseAddress, let key = word.baseAddress
                else { return false }
                return memmem(base, text.count, key, word.count) != nil
            }
        }
    }
}
