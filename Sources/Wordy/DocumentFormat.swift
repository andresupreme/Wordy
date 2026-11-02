import AppKit
import PDFKit
import UniformTypeIdentifiers

enum DocumentError: LocalizedError {
    case unreadable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file could not be read as text."
        case .writeFailed: return "The file could not be created."
        }
    }
}

/// Text read from a plain-text file, with the encoding it was stored in, so
/// saving can write it back the same way.
struct DecodedText {
    var text: String
    var encoding: String.Encoding
    /// True when the file began with a UTF-8 byte-order mark. The BOM is not
    /// part of the text, but it is put back when the file is saved again.
    var hasUTF8BOM: Bool = false
}

/// Every format Wordy can import and export.
enum DocumentFormat: String, CaseIterable, Identifiable {
    case txt, md, rtf, html, docx, doc, odt, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .md: return "Markdown (.md)"
        case .rtf: return "Rich Text (.rtf)"
        case .html: return "Web Page (.html)"
        case .docx: return "Word Document (.docx)"
        case .doc: return "Word 97–2003 (.doc)"
        case .odt: return "OpenDocument (.odt)"
        case .pdf: return "PDF (.pdf)"
        }
    }

    var fileExtension: String { rawValue }
    var utType: UTType { UTType(filenameExtension: rawValue) ?? .data }
    var isPlainText: Bool { self == .txt || self == .md }

    static func detect(_ url: URL) -> DocumentFormat {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown": return .md
        case "rtf": return .rtf
        case "html", "htm", "xhtml": return .html
        case "docx": return .docx
        case "doc": return .doc
        case "odt": return .odt
        case "pdf": return .pdf
        default: return .txt
        }
    }

    static var importTypes: [UTType] {
        [.plainText, .text] + allCases.map(\.utType)
    }

    private var attributedType: NSAttributedString.DocumentType? {
        switch self {
        case .rtf: return .rtf
        case .html: return .html
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .odt: return .openDocument
        default: return nil
        }
    }

    // MARK: - Import (always ends up as plain text)

    func readText(from url: URL) throws -> String {
        if self == .pdf {
            guard let text = PDFDocument(url: url)?.string else { throw DocumentError.unreadable }
            return text
        }
        let data = try Data(contentsOf: url)
        if let type = attributedType {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: type],
                documentAttributes: nil
            )
            return attributed.string
        }
        return try Self.decodePlainText(data).text
    }

    // MARK: - Plain-text decoding

    /// Finds out how a text file is encoded. A byte-order mark is conclusive
    /// and valid UTF-8 is almost certainly UTF-8. Older files are decided
    /// between Windows-1251 and Windows-1252, the two single-byte encodings
    /// Wordy is most likely to meet.
    static func decodePlainText(_ data: Data) throws -> DecodedText {
        if data.isEmpty { return DecodedText(text: "", encoding: .utf8) }

        if data.starts(with: [0xEF, 0xBB, 0xBF] as [UInt8]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            // Remember the BOM so saving the same file does not silently remove it.
            return DecodedText(text: text, encoding: .utf8, hasUTF8BOM: true)
        }
        if data.starts(with: [0xFF, 0xFE] as [UInt8]) || data.starts(with: [0xFE, 0xFF] as [UInt8]),
           let text = String(data: data, encoding: .utf16) {
            return DecodedText(text: text, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8)
        }

        // Windows-1251 and Windows-1252 both decode almost any byte sequence,
        // so the text itself has to decide. Counting non-ASCII characters, as
        // the previous version did, made every Western accented file look
        // Cyrillic. Count all letters instead and, more importantly, reject a
        // Windows-1251 reading that leaves Latin and Cyrillic letters mixed
        // inside words: that is the fingerprint of a Western word such as
        // "Résumé" being read as "Rйsumй".
        let cp1251 = String(data: data, encoding: .windowsCP1251)
        let cp1252 = String(data: data, encoding: .windowsCP1252)
        if let cp1251, let cp1252 {
            return looksCyrillic(cp1251)
                ? DecodedText(text: cp1251, encoding: .windowsCP1251)
                : DecodedText(text: cp1252, encoding: .windowsCP1252)
        }
        if let cp1252 {
            return DecodedText(text: cp1252, encoding: .windowsCP1252)
        }
        if let cp1251 {
            return DecodedText(text: cp1251, encoding: .windowsCP1251)
        }
        for encoding in [String.Encoding.macOSRoman, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return DecodedText(text: text, encoding: encoding)
            }
        }
        // ISO Latin-1 maps every byte, so this is only a safety net.
        throw DocumentError.unreadable
    }

    /// True when a Windows-1251 reading of the bytes really looks Cyrillic.
    ///
    /// Two signals are used. First, real Cyrillic files are mostly Cyrillic
    /// letters. Second, and more useful for short text, a Western word decoded
    /// as Windows-1251 almost always becomes a *mixed-script* word ("déjà"
    /// becomes "dйjа", "schön" becomes "schцn"). A genuine Russian word such
    /// as "Привет" stays entirely Cyrillic, and a Russian document that uses
    /// English terms has them as separate Latin-only words.
    private static func looksCyrillic(_ text: String) -> Bool {
        var cyrillic = 0
        var latin = 0
        var words = 0
        var mixedWords = 0
        var longCyrillicWords = 0

        var wordCyrillic = 0
        var wordLatin = 0

        func endWord() {
            guard wordCyrillic > 0 || wordLatin > 0 else { return }
            words += 1
            if wordCyrillic > 0 && wordLatin > 0 { mixedWords += 1 }
            if wordCyrillic >= 3 && wordLatin == 0 { longCyrillicWords += 1 }
            wordCyrillic = 0
            wordLatin = 0
        }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
                wordCyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                latin += 1
                wordLatin += 1
            default:
                endWord()
            }
        }
        endWord()

        let letters = cyrillic + latin
        guard letters > 0 else { return false }

        let cyrillicShare = Double(cyrillic) / Double(letters)
        let mixedShare = words > 0 ? Double(mixedWords) / Double(words) : 0

        // "Résumé" decoded as Windows-1251 is mixed inside every accented
        // word; that outweighs even a high Cyrillic letter count.
        if mixedShare >= 0.2 { return false }

        // Text with a substantial Cyrillic presence, or at least one real
        // Cyrillic word, is Cyrillic. The word check also handles a mostly
        // English document quoting a Russian phrase without turning one
        // standalone accented letter ("à") into a whole encoding decision.
        return cyrillicShare > 0.4 || longCyrillicWords >= 1
    }

    // MARK: - Export

    func write(text: String, font: EditorFont, size: CGFloat, to url: URL) throws {
        switch self {
        case .txt, .md:
            try text.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            try Self.writePDF(Self.attributedString(text, font: font, size: size), to: url)
        default:
            let attributed = Self.attributedString(text, font: font, size: size)
            guard let type = attributedType else { throw DocumentError.writeFailed }
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: type]
            )
            try data.write(to: url, options: .atomic)
        }
    }

    /// Exported documents are always dark text on white, in the font chosen in the editor.
    private static func attributedString(_ text: String, font: EditorFont, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.2
        return NSAttributedString(string: text, attributes: [
            .font: font.nsFont(size: size),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ])
    }

    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842) // A4
        info.topMargin = 64
        info.bottomMargin = 64
        info.leftMargin = 64
        info.rightMargin = 64
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = NSPrintOperation(view: printView(for: attributed, info: info), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw DocumentError.writeFailed }
    }

    /// Shows the standard macOS Print dialog for the current text.
    static func printDocument(text: String, font: EditorFont, size: CGFloat) {
        let attributed = attributedString(text, font: font, size: size)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 64
        info.bottomMargin = 64
        info.leftMargin = 64
        info.rightMargin = 64
        let operation = NSPrintOperation(view: printView(for: attributed, info: info), printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private static func printView(for attributed: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(attributed)

        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            textView.setFrameSize(NSSize(width: width, height: max(layout.usedRect(for: container).height + 20, 100)))
        }
        return textView
    }
}
