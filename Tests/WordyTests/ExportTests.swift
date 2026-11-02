import XCTest
@testable import Wordy

final class ExportTests: XCTestCase {
    func testEveryExportFormatProducesAReadableDocument() throws {
        let text = "Hello, Wordy!\n\nSecond paragraph with ünïcode and Цириллица.\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordy-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in DocumentFormat.allCases {
            let url = directory.appendingPathComponent("sample." + format.fileExtension)
            try format.write(text: text, font: .helvetica, size: 14, to: url)

            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 0, "\(format.rawValue) export is empty")

            let back = try format.readText(from: url)
            XCTAssertTrue(back.contains("Second paragraph"), "\(format.rawValue) round-trip lost text: \(back.prefix(80))")
        }
    }
}
