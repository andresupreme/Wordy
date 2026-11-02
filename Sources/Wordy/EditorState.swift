import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class EditorState: ObservableObject {
    var id = UUID()
    weak var window: NSWindow?

    @Published var text: String = "" {
        didSet { if !isLoading && text != oldValue { isDirty = true } }
    }
    /// Set only for plain-text files (.txt / .md) that Save can overwrite directly.
    @Published var fileURL: URL?
    @Published var isDirty = false {
        didSet {
            if isDirty {
                scheduleDraft()
            } else {
                draftWork?.cancel()
                draftWork = nil
                draftDeadline = nil
                DraftStore.delete(id: id)
            }
        }
    }

    /// How the open file is encoded on disk. Saving into the same file writes it
    /// back in this encoding, so old files are never silently converted.
    @Published private(set) var fileEncoding: String.Encoding = .utf8

    /// A UTF-8 file can start with a byte-order mark. It is not part of the
    /// text, but it is put back when the file is saved again.
    @Published private(set) var fileHasUTF8BOM = false

    /// Name of an imported rich document (docx, rtf, ...). Save never overwrites those.
    private var importedName: String?
    private var isLoading = false
    private var draftWork: DispatchWorkItem?
    /// The latest time a draft may wait while typing never pauses. Without this
    /// the debounce in scheduleDraft() would be reset forever by continuous
    /// typing and nothing would reach disk.
    private var draftDeadline: Date?
    private let draftDebounce: TimeInterval = 0.8
    private let draftMaxWait: TimeInterval = 5.0

    init() {
        StateRegistry.shared.register(self)
    }

    var isBlank: Bool { text.isEmpty && fileURL == nil && importedName == nil }

    /// An empty, never-saved document has nothing worth asking about.
    var needsSavePrompt: Bool { isDirty && !isBlank }

    /// Shown with the word count when the file is not plain UTF-8.
    var encodingNote: String? {
        if fileEncoding == .utf8 {
            return fileHasUTF8BOM ? "UTF-8 with BOM" : nil
        }
        return String.localizedName(of: fileEncoding)
    }

    var displayName: String {
        fileURL?.lastPathComponent ?? importedName ?? "Untitled"
    }

    private var baseName: String {
        if let url = fileURL { return url.deletingPathExtension().lastPathComponent }
        return importedName.map { ($0 as NSString).deletingPathExtension } ?? "Untitled"
    }

    // MARK: - Windows and tabs

    func newDocument() { OpenRouter.shared.newTab() }
    func open() { OpenRouter.shared.openPanel(from: self) }

    func reveal() {
        guard let window = window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Open / Import

    func openFile(at url: URL) {
        let format = DocumentFormat.detect(url)
        do {
            if format.isPlainText {
                // Remember the encoding so saving writes the file back unchanged.
                let decoded = try DocumentFormat.decodePlainText(Data(contentsOf: url))
                load(
                    text: decoded.text,
                    url: url,
                    importedName: nil,
                    encoding: decoded.encoding,
                    hasUTF8BOM: decoded.hasUTF8BOM
                )
            } else {
                let content = try format.readText(from: url)
                load(text: content, url: nil, importedName: url.lastPathComponent)
            }
            RecentDocuments.shared.note(url)
        } catch {
            showError("Could not open \(url.lastPathComponent)", error)
        }
    }

    // MARK: - Save (plain text)

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return writePlain(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        // A Markdown file stays Markdown; everything else is saved as .txt.
        let isMarkdown = fileURL.map { DocumentFormat.detect($0) == .md } ?? false
        let format: DocumentFormat = isMarkdown ? .md : .txt
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = baseName + "." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writePlain(to: url)
    }

    private func writePlain(to url: URL) -> Bool {
        // Saving into the same file keeps its original encoding; a new file is UTF-8.
        let sameFile = url.standardizedFileURL == fileURL?.standardizedFileURL
        var encoding: String.Encoding = sameFile ? fileEncoding : .utf8
        // A UTF-8 BOM belongs to the original file, not to new documents.
        var writeUTF8BOM = sameFile && encoding == .utf8 && fileHasUTF8BOM

        var encoded = text.data(using: encoding, allowLossyConversion: false)
        if encoded == nil {
            // Characters were typed that the old encoding cannot hold.
            guard confirmUTF8Fallback(from: encoding, file: url.lastPathComponent) else { return false }
            encoding = .utf8
            writeUTF8BOM = false
            encoded = text.data(using: .utf8)
        }
        guard var bytes = encoded else {
            showError("Could not save \(url.lastPathComponent)", DocumentError.writeFailed)
            return false
        }
        if writeUTF8BOM {
            bytes = Data([0xEF, 0xBB, 0xBF]) + bytes
        }

        do {
            try bytes.write(to: url, options: .atomic)
            fileURL = url
            fileEncoding = encoding
            fileHasUTF8BOM = writeUTF8BOM
            importedName = nil
            isDirty = false
            RecentDocuments.shared.note(url)
            return true
        } catch {
            showError("Could not save \(url.lastPathComponent)", error)
            return false
        }
    }

    // MARK: - Export and print

    func exportDocument(font: EditorFont, size: CGFloat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        let picker = FormatPicker(panel: panel, baseName: baseName, initial: .docx)

        guard panel.runModal() == .OK, var url = panel.url else { return }
        let format = picker.selected
        if url.pathExtension.lowercased() != format.fileExtension {
            url.appendPathExtension(format.fileExtension)
        }
        do {
            try format.write(text: text, font: font, size: size, to: url)
        } catch {
            showError("Could not export \(url.lastPathComponent)", error)
        }
    }

    func printDocument(font: EditorFont, size: CGFloat) {
        DocumentFormat.printDocument(text: text, font: font, size: size)
    }

    // MARK: - Autosave / recovery

    private func scheduleDraft() {
        draftWork?.cancel()
        let now = Date()
        if draftDeadline == nil {
            draftDeadline = now.addingTimeInterval(draftMaxWait)
        }
        // Normally wait for a pause in typing, but never longer than the
        // deadline: someone typing steadily should still get drafts on disk.
        let remaining = max(0, draftDeadline?.timeIntervalSince(now) ?? 0)
        let delay = min(draftDebounce, remaining)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.draftWork = nil
            self.draftDeadline = nil
            self.writeDraftNow()
        }
        draftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func writeDraftNow() {
        // Flush from quit/resign-active should also drop any pending debounce.
        draftWork?.cancel()
        draftWork = nil
        draftDeadline = nil

        guard isDirty else { return }
        // A blank, unnamed document is not worth recovering.
        if isBlank {
            DraftStore.delete(id: id)
            return
        }
        DraftStore.save(Draft(
            id: id,
            text: text,
            filePath: fileURL?.path,
            importedName: importedName,
            encodingRaw: fileEncoding == .utf8 ? nil : fileEncoding.rawValue,
            hasUTF8BOM: fileHasUTF8BOM
        ))
    }

    func restore(_ draft: Draft) {
        isLoading = true
        id = draft.id
        text = draft.text
        fileURL = draft.filePath.map { URL(fileURLWithPath: $0) }
        importedName = draft.importedName
        fileEncoding = draft.encodingRaw.map { String.Encoding(rawValue: $0) } ?? .utf8
        fileHasUTF8BOM = draft.hasUTF8BOM ?? false
        isLoading = false
        isDirty = true // keeps the draft alive until it is saved or discarded
    }

    func windowDidClose() {
        draftWork?.cancel()
        draftWork = nil
        draftDeadline = nil
        // When the whole app is quitting, keep drafts so they come back next launch.
        if !StateRegistry.shared.isTerminating { DraftStore.delete(id: id) }
    }

    // MARK: - Helpers

    private func load(
        text: String,
        url: URL?,
        importedName: String?,
        encoding: String.Encoding = .utf8,
        hasUTF8BOM: Bool = false
    ) {
        isLoading = true
        self.text = text
        self.fileURL = url
        self.importedName = importedName
        self.fileEncoding = encoding
        self.fileHasUTF8BOM = hasUTF8BOM
        isLoading = false
        isDirty = false
    }

    /// Returns true if it is OK to continue (saved, discarded, or nothing to lose).
    func confirmDiscardIfNeeded() -> Bool {
        guard needsSavePrompt else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            // Truly discard: this also removes the recovery draft.
            isDirty = false
            return true
        default:
            return false
        }
    }

    private func confirmUTF8Fallback(from encoding: String.Encoding, file: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some characters can't be saved in the file's original encoding"
        alert.informativeText = "“\(file)” uses \(String.localizedName(of: encoding)), which cannot hold every character in the text now. Wordy can save it as UTF-8 instead."
        alert.addButton(withTitle: "Save as UTF-8")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// The "Format:" pop-up shown at the bottom of the Export panel.
final class FormatPicker: NSObject {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    var selected: DocumentFormat {
        let index = max(0, popup.indexOfSelectedItem)
        return DocumentFormat.allCases[index]
    }

    init(panel: NSSavePanel, baseName: String, initial: DocumentFormat) {
        self.panel = panel
        super.init()

        popup.addItems(withTitles: DocumentFormat.allCases.map(\.title))
        popup.selectItem(at: DocumentFormat.allCases.firstIndex(of: initial) ?? 0)
        popup.target = self
        popup.action = #selector(changed)

        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.setFrameSize(stack.fittingSize)

        panel.accessoryView = stack
        panel.nameFieldStringValue = baseName + "." + initial.fileExtension
        panel.allowedContentTypes = [initial.utType]
    }

    @objc private func changed() {
        guard let panel = panel else { return }
        let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = [selected.utType]
        panel.nameFieldStringValue = current + "." + selected.fileExtension
    }
}
