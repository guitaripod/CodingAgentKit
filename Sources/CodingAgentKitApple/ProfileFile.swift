import Foundation

/// The stored profile list as a build that may not understand all of it sees it.
///
/// A client is not always the newest thing that has written this file — an older release run again,
/// a machine two versions behind, a file carried over from another install — and what it meets
/// there is a server whose backend it has no case for. Decoding the list as one array throws on
/// that single entry, and the throw is the whole list: every server disappears from a read that
/// swallows it, and the next save fails with a raw decoding error instead of saving. One server a
/// build cannot name should never cost a person the servers it can.
///
/// So each entry is read on its own, and an entry that will not decode is kept as the bytes it was
/// and written back in place rather than dropped — a build that cannot talk to a server still must
/// not be the reason it is gone the next time something is saved.
public struct ProfileFile: Sendable, Equatable {
    public var known: [ConnectionProfile]
    public var unreadable: [Data]

    public init(known: [ConnectionProfile] = [], unreadable: [Data] = []) {
        self.known = known
        self.unreadable = unreadable
    }

    /// Malformed bytes still throw: a file that is not a JSON array at all is a read failure, and
    /// answering one with an empty list would let the next save rebuild the file from nothing.
    public static func read(_ data: Data) throws -> ProfileFile {
        guard !data.isEmpty else { return ProfileFile() }
        guard let elements = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "stored profiles are not a JSON array"))
        }
        let decoder = JSONDecoder()
        var file = ProfileFile()
        for element in elements {
            guard let bytes = try? JSONSerialization.data(withJSONObject: element) else { continue }
            if let profile = try? decoder.decode(ConnectionProfile.self, from: bytes) {
                file.known.append(profile)
            } else {
                file.unreadable.append(bytes)
            }
        }
        return file
    }

    /// The entries this build understands, then the ones it does not, in the formatting both
    /// stores have always written so a rewrite of an unchanged list is an unchanged file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        var elements: [Any] = []
        for profile in known {
            elements.append(try JSONSerialization.jsonObject(with: encoder.encode(profile)))
        }
        for bytes in unreadable {
            guard let object = try? JSONSerialization.jsonObject(with: bytes) else { continue }
            elements.append(object)
        }
        return try JSONSerialization.data(
            withJSONObject: elements, options: [.prettyPrinted, .sortedKeys])
    }

    public mutating func replace(_ profile: ConnectionProfile) {
        known.removeAll { $0.id == profile.id }
        known.append(profile)
    }

    public mutating func remove(id: String) {
        known.removeAll { $0.id == id }
    }
}
