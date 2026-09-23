import Foundation

/// One decoder and one encoder for the whole process. They were computed properties, so every
/// access built a fresh coder, once per server-sent frame while a turn streams, for a
/// configuration that never changes and objects that are safe to share.
public enum JSONCoding {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
