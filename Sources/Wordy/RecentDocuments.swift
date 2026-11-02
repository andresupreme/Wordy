import SwiftUI
import AppKit

/// The File > Open Recent menu contents. NSDocumentController owns the list;
/// this object publishes it to SwiftUI and refreshes when the app activates.
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()

    @Published private(set) var urls: [URL] = []
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let recent = NSDocumentController.shared.recentDocumentURLs
        if recent != urls { urls = recent }
    }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
}
