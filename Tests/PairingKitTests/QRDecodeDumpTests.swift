import Foundation
import Testing

@testable import PairingKit

@Suite struct QRDecodeDumpTests {
    private struct Dump: Codable {
        var name: String
        var level: String
        var payload: String
        var version: Int
        var rows: [String]
    }

    @Test func writesMatricesForTheExternalDecoderWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["PAIRINGKIT_DUMP_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        for payload in QRPayloads.all() {
            for level in QRLevel.allCases where payload.text.utf8.count <= QRCode.capacity(level: level) {
                let code = try QRCode.encode(payload.text, level: level)
                let rows = code.modules.map { row in String(row.map { $0 ? Character("1") : Character("0") }) }
                let dump = Dump(
                    name: payload.name, level: "\(level)", payload: payload.text, version: code.version, rows: rows)
                let file = folder.appendingPathComponent("\(payload.name)-\(level).json")
                try JSONEncoder().encode(dump).write(to: file)
                let ansi = folder.appendingPathComponent("\(payload.name)-\(level).ansi")
                try Data(TerminalQR.ansi(code).utf8).write(to: ansi)
                written += 1
            }
        }
        #expect(written > 0)
    }
}
