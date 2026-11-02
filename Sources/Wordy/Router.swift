import SwiftUI
import AppKit

/// Weak list of every open document, so files can be routed to a blank
/// window, a duplicate can be brought forward, and drafts flushed on quit.
final class StateRegistry {
    static let shared = StateRegistry()
    private let table = NSHashTable<EditorState>.weakObjects()
    var isTerminating = false

    func register(_ state: EditorState) { table.add(state) }
    var all: [EditorState] { table.allObjects }

    func state(forFile url: URL) -> EditorState? {
        all.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
    }

    /// The document whose window is this one. Used by the menu commands to
    /// follow the key window without relying on SwiftUI focus values.
    func state(forWindow window: NSWindow?) -> EditorState? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// Prefers a blank document that is already in a window. One whose window
    /// has not attached yet (during app launch) is still a valid fallback.
    func firstBlank() -> EditorState? {
        let blanks = all.filter { $0.isBlank }
        return blanks.first { $0.window != nil } ?? blanks.first
    }

    func flushAll() { all.forEach { $0.writeDraftNow() } }
}

/// Decides where files and recovered drafts go: into a blank window if there
/// is one, otherwise into a new tab.
final class OpenRouter {
    static let shared = OpenRouter()

    var pendingURLs: [URL] = []
    var pendingDrafts: [Draft] = []
    private var isTabScheduled = false

    /// Called by every new window. Hands it a recovered draft or a queued file.
    func claim(for state: EditorState) {
        guard state.isBlank else { return }
        if !pendingDrafts.isEmpty {
            state.restore(pendingDrafts.removeFirst())
        } else if !pendingURLs.isEmpty {
            state.openFile(at: pendingURLs.removeFirst())
        }
        // More waiting? Each new tab claims the next one. Only one delayed tab
        // is ever in flight, and it re-checks the queue: several windows can
        // claim drafts in the same run-loop turn, and without both guards that
        // would leave a trail of empty tabs.
        if !pendingDrafts.isEmpty || !pendingURLs.isEmpty {
            scheduleNextTab()
        }
    }

    private func scheduleNextTab() {
        guard !isTabScheduled else { return }
        isTabScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.isTabScheduled = false
            guard !self.pendingDrafts.isEmpty || !self.pendingURLs.isEmpty else { return }
            self.newTab()
        }
    }

    func newTab() {
        // Use a real document window, never Help or a save panel. The key window
        // is preferred so a new tab joins the group the user is looking at.
        let windows = StateRegistry.shared.all.compactMap(\.window)
        guard let current = windows.first(where: { $0.isKeyWindow })
            ?? windows.first(where: { $0.isVisible })
            ?? windows.first,
              let controller = current.windowController else { return }

        let identifier = current.tabbingIdentifier
        let frame = current.frame
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.newWindowForTab(nil)

        // newWindowForTab does not always make the new window key immediately,
        // so find it by diffing the window list instead of trusting keyWindow.
        guard let created = NSApp.windows.first(where: {
            !before.contains(ObjectIdentifier($0)) && $0 !== current
        }) else { return }

        // Make sure the new window is compatible with the current tab group,
        // then attach it explicitly for SwiftUI-created window controllers.
        if !identifier.isEmpty { created.tabbingIdentifier = identifier }
        created.tabbingMode = .preferred
        created.setFrame(frame, display: false)
        current.addTabbedWindow(created, ordered: .above)
        created.makeKeyAndOrderFront(nil)
        // Adding a tab can adopt the new window's default size; keep the
        // size the current window already had.
        current.setFrame(frame, display: true)
    }

    func openPanel(from state: EditorState?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentFormat.importTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url, preferring: state) }
    }

    func open(_ url: URL, preferring state: EditorState?) {
        if let existing = StateRegistry.shared.state(forFile: url) {
            existing.reveal()
            return
        }
        if let state = state, state.isBlank {
            state.openFile(at: url)
            return
        }
        if let blank = StateRegistry.shared.firstBlank() {
            blank.openFile(at: url)
            blank.reveal()
            return
        }
        pendingURLs.append(url)
        newTab()
    }
}
