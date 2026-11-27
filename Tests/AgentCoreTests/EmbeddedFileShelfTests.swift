import Foundation
import Testing

@testable import AgentCore

@Suite struct EmbeddedFileShelfTests {
    private func shelf() -> (EmbeddedFileShelf, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)", isDirectory: true)
        return (EmbeddedFileShelf(directory: directory), directory)
    }

    private func picture(_ seed: UInt8, count: Int = 9000) -> (url: String, bytes: Data) {
        let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        return ("data:image/png;base64," + bytes.base64EncodedString(), bytes)
    }

    @Test func aPictureIsShelvedAndReadBack() throws {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, bytes) = picture(1)
        let reference = try #require(shelf.shelved(url))
        #expect(EmbeddedFileShelf.isShelved(reference))
        #expect(reference.utf8.count < 80)
        #expect(shelf.bytes(of: reference) == bytes)
        #expect(shelf.shelved(url) == reference)
    }

    @Test func differentPicturesHaveDifferentReferences() {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(shelf.shelved(picture(1).url) != shelf.shelved(picture(2).url))
    }

    @Test func whatIsNotWorthShelvingStaysAsItWas() {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(shelf.shelved("data:image/png;base64,AAAA") == "data:image/png;base64,AAAA")
        #expect(shelf.shelved("/files/raw?path=a.png") == "/files/raw?path=a.png")
        #expect(shelf.shelved(nil as String?) == nil)
        let long = "https://example.com/" + String(repeating: "a", count: 5000)
        #expect(shelf.shelved(long) == long)
    }

    @Test func aReferenceKeepsTheTypeItsURLNamed() {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = shelf.shelved(FileReference(url: picture(3).url, filename: "shot"))
        #expect(kept.mime == "image/png")
        #expect(kept.filename == "shot")
        #expect(kept.url.map(EmbeddedFileShelf.isShelved) == true)
    }

    @Test func aDiskThatRefusesLeavesTheURL() {
        let blocked = URL(fileURLWithPath: "/dev/null/shelf", isDirectory: true)
        let url = picture(4).url
        #expect(EmbeddedFileShelf(directory: blocked).shelved(url) == url)
    }

    @Test func aReferenceCannotLeaveTheShelf() {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = shelf.shelved(picture(5).url)
        #expect(shelf.bytes(of: EmbeddedFileShelf.scheme + "../x") == nil)
        #expect(shelf.bytes(of: EmbeddedFileShelf.scheme + "missing") == nil)
        #expect(shelf.bytes(of: "data:text/plain,hi") == nil)
    }

    @Test func tidyingClearsWhatNothingAskedForInAMonth() throws {
        let (shelf, directory) = shelf()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try #require(shelf.shelved(picture(6).url))
        let later = EmbeddedFileShelf(directory: directory)
        let fresh = try #require(later.shelved(picture(7).url))
        later.tidy(now: Date().addingTimeInterval(EmbeddedFileShelf.keptFor + 60))
        #expect(later.bytes(of: old) == nil)
        #expect(later.bytes(of: fresh) != nil)
    }
}
