import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unsaved work from the last session (crash, or quit with edits) comes back.
        OpenRouter.shared.pendingDrafts = DraftStore.loadAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running as a bare SwiftPM executable (no .app bundle yet).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Menu commands follow the key window's document.
        ActiveDocument.shared.startTracking()

        // ⌘= (no Shift) also makes the text bigger, like ⌘+. The menu only
        // knows ⌘+, which on most keyboards needs Shift.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "=" else { return event }
            let stored = UserDefaults.standard.double(forKey: PrefKey.fontSize)
            let size = stored == 0 ? 16.0 : stored
            UserDefaults.standard.set(min(size + 1, 48), forKey: PrefKey.fontSize)
            return nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ActiveDocument.shared.refreshFromKeyWindow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Switching to another app is a good moment to make sure every edited
        // document is on disk, even one that is being typed in continuously.
        StateRegistry.shared.all.filter(\.isDirty).forEach { $0.writeDraftNow() }
    }

    /// Finder double-click, drag onto the Dock icon, "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { OpenRouter.shared.open(url, preferring: nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if StateRegistry.shared.isTerminating { return .terminateNow }

        let dirty = StateRegistry.shared.all.filter(\.needsSavePrompt)

        // Nothing to lose: quit straight away.
        guard !dirty.isEmpty else {
            StateRegistry.shared.isTerminating = true
            StateRegistry.shared.flushAll()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to “\(dirty[0].displayName)”?"
            : "You have unsaved changes in \(dirty.count) documents."
        alert.informativeText = "You can save them now, or quit and keep them as drafts to restore next time."
        alert.addButton(withTitle: "Save All…")
        alert.addButton(withTitle: "Keep Drafts and Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for state in dirty where !state.save() {
                return .terminateCancel
            }
            StateRegistry.shared.isTerminating = true
            StateRegistry.shared.flushAll()
            return .terminateNow
        case .alertSecondButtonReturn:
            // Drafts stay on disk and come back at next launch.
            StateRegistry.shared.isTerminating = true
            StateRegistry.shared.flushAll()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WordyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Files are routed by AppDelegate, so SwiftUI must not open extra windows.
        .handlesExternalEvents(matching: Set<String>())
        .commands { WordyCommands() }
    }
}

struct WordyCommands: Commands {
    @ObservedObject private var recents = RecentDocuments.shared

    @AppStorage(PrefKey.theme) private var themeRaw = Theme.white.rawValue
    @AppStorage(PrefKey.font) private var fontRaw = EditorFont.helvetica.rawValue
    @AppStorage(PrefKey.fontSize) private var fontSize = 16.0
    @AppStorage(PrefKey.lineWidth) private var lineWidthRaw = LineWidth.medium.rawValue
    @AppStorage(PrefKey.typewriter) private var typewriter = false
    @AppStorage(PrefKey.focusMode) private var focusMode = false
    @AppStorage(PrefKey.spellingCheck) private var spellingCheck = false

    private var font: EditorFont { EditorFont(rawValue: fontRaw) ?? .helvetica }

    /// Read at the moment a menu item runs, so it always means the document in
    /// the key window. SwiftUI's focused values never became non-nil here
    /// because the editor is an AppKit text view.
    private var activeState: EditorState? { ActiveDocument.shared.state }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { OpenRouter.shared.newTab() }
                .keyboardShortcut("n")
            Button("Open…") { OpenRouter.shared.openPanel(from: activeState) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Menu("Open Recent") {
                if recents.urls.isEmpty {
                    Button("No Recent Documents") {}
                        .disabled(true)
                } else {
                    ForEach(recents.urls.prefix(10), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            OpenRouter.shared.open(url, preferring: activeState)
                        }
                        .help(url.path)
                    }
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                }
            }
            Divider()
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            // These deliberately stay enabled. SwiftUI builds the command items
            // from the state at launch and does not reliably re-enable them when
            // the active document changes, which is how Save used to end up
            // permanently disabled. The action reads the active document
            // instead, and quietly does nothing when there is none.
            Button("Save") { activeState?.save() }
                .keyboardShortcut("s")
            Button("Save As…") { activeState?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export…") { activeState?.exportDocument(font: font, size: fontSize) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { activeState?.printDocument(font: font, size: fontSize) }
                .keyboardShortcut("p")
        }
        CommandGroup(replacing: .toolbar) {
            // Without this the View menu is empty and the ⌃⌘F shortcut that
            // Help promises does not exist.
            Button("Toggle Full Screen") {
                ActiveDocument.shared.state?.window?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("Appearance") {
            Picker("Theme", selection: $themeRaw) {
                ForEach(Theme.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Font", selection: $fontRaw) {
                ForEach(EditorFont.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Line Width", selection: $lineWidthRaw) {
                ForEach(LineWidth.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button("Bigger") { fontSize = min(fontSize + 1, 48) }
                .keyboardShortcut("+")
            Button("Smaller") { fontSize = max(fontSize - 1, 9) }
                .keyboardShortcut("-")
        }
        CommandMenu("Writing") {
            Toggle("Typewriter Scrolling", isOn: $typewriter)
            Toggle("Focus Mode", isOn: $focusMode)
            Toggle("Spelling Check", isOn: $spellingCheck)
        }
        CommandGroup(replacing: .help) {
            Button("Wordy Help") { HelpWindow.shared.show(.start) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Button("Keyboard Shortcuts") { HelpWindow.shared.show(.shortcuts) }
            Button("Formats & Files") { HelpWindow.shared.show(.formats) }
            Button("Tips") { HelpWindow.shared.show(.tips) }
            Divider()
            Button("Show Saved Drafts in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([DraftStore.directory])
            }
        }
    }
}
