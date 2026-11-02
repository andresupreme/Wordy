import AppKit
import Combine

/// The document that menu commands should act on: the one in the key window.
///
/// SwiftUI's focused values are not usable here. Wordy's editor is an AppKit
/// text view, so SwiftUI never has a focused view to publish a focused object
/// from, and the menu commands built from `@FocusedObject` stayed permanently
/// disabled. Tracking the key window explicitly is both simpler and reliable.
final class ActiveDocument: ObservableObject {
    static let shared = ActiveDocument()

    @Published private(set) var state: EditorState?
    private var observers: [NSObjectProtocol] = []

    func activate(_ state: EditorState?) {
        if self.state !== state { self.state = state }
    }

    func deactivate(_ state: EditorState?) {
        if self.state === state { self.state = nil }
    }

    /// Starts following the key window. Safe to call more than once.
    func startTracking() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if let state = StateRegistry.shared.state(forWindow: window) {
                self.activate(state)
            } else {
                // Help, a save panel, an alert, and so on must not leave a
                // document command pointed at some other window. A new document
                // window that has not attached its EditorState yet is picked up
                // by WindowChrome as soon as it does.
                self.activate(nil)
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if self.state?.window === window { self.activate(nil) }
        })

        DispatchQueue.main.async { [weak self] in self?.refreshFromKeyWindow() }
    }

    func refreshFromKeyWindow() {
        guard let window = NSApp.keyWindow else { return }
        if let state = StateRegistry.shared.state(forWindow: window) {
            activate(state)
        } else {
            activate(nil)
        }
    }
}
