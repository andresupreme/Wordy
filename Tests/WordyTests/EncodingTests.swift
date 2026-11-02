import XCTest
@testable import Wordy

final class EncodingTests: XCTestCase {
    func testWindows1252IsNotMistakenForCyrillic() throws {
        let samples = [
            "Résumé déjà vu, café.",
            "Grüße aus München",
            "¿Qué tal? Mañana será otro día.",
            "À noite, ele escreveu “olá” — e dormiu.",
            "Perché è così? Città, più, però.",
            "Je vais à Paris, où il fait beau.",
            "Été",
            "où",
        ]
        for text in samples {
            let data = text.data(using: .windowsCP1252)!
            let decoded = try DocumentFormat.decodePlainText(data)
            XCTAssertEqual(decoded.text, text, "Windows-1252 text was mangled")
            XCTAssertEqual(decoded.encoding, .windowsCP1252)
            XCTAssertEqual(decoded.text.data(using: decoded.encoding), data, "bytes changed")
        }
    }

    func testWindows1251StillWorks() throws {
        let samples = [
            "Привет, мир! Это тест.",
            "Это длинный русский текст. Он содержит macOS и Wordy.",
            "Привіт, світе! Це тест.",
            "Здравей, свят! Това е тест.",
            "Привет",
            "Да",
            "The report says: «Это очень важно» for everyone.",
        ]
        for text in samples {
            let data = text.data(using: .windowsCP1251)!
            let decoded = try DocumentFormat.decodePlainText(data)
            XCTAssertEqual(decoded.text, text, "Windows-1251 text was mangled")
            XCTAssertEqual(decoded.encoding, .windowsCP1251)
            XCTAssertEqual(decoded.text.data(using: decoded.encoding), data, "bytes changed")
        }
    }

    func testUTF8BOMIsReported() throws {
        let text = "Hello, BOM"
        let data = Data([0xEF, 0xBB, 0xBF]) + text.data(using: .utf8)!
        let decoded = try DocumentFormat.decodePlainText(data)
        XCTAssertEqual(decoded.text, text)
        XCTAssertTrue(decoded.hasUTF8BOM)
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testPlainUTF8DoesNotClaimABOM() throws {
        let decoded = try DocumentFormat.decodePlainText("Résumé — UTF-8".data(using: .utf8)!)
        XCTAssertFalse(decoded.hasUTF8BOM)
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testEmptyFile() throws {
        let decoded = try DocumentFormat.decodePlainText(Data())
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.encoding, .utf8)
    }
}
