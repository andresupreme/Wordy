import Foundation

/// Snapshot of an unsaved document, written to disk while you type so nothing
/// is lost after a crash, a power cut, or quitting with unsaved changes.
struct Draft: Codable {
    var id: UUID
    var text: String
    var filePath: String?
    var importedName: String?
    /// Raw value of the file's original encoding; nil means UTF-8.
    var encodingRaw: UInt?
    /// Whether the original UTF-8 file started with a byte-order mark.
    var hasUTF8BOM: Bool?
}

enum DraftStore {
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wordy/Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    static func save(_ draft: Draft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: url(for: draft.id), options: .atomic)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static func loadAll() -> [Draft] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        return sorted.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let draft = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
            // An empty, unnamed draft is not worth bringing back as a blank tab.
            if draft.text.isEmpty, draft.filePath == nil, draft.importedName == nil {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return draft
        }
    }
}
