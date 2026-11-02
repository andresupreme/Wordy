import SwiftUI
import AppKit

enum HelpTab: String, CaseIterable, Identifiable {
    case start = "Getting Started"
    case shortcuts = "Shortcuts"
    case formats = "Formats & Files"
    case tips = "Tips"
    var id: String { rawValue }
}

final class HelpModel: ObservableObject {
    @Published var tab: HelpTab = .start
}

/// One shared Help window, opened from the Help menu.
final class HelpWindow {
    static let shared = HelpWindow()
    private let model = HelpModel()
    private var window: NSWindow?

    func show(_ tab: HelpTab) {
        model.tab = tab
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Wordy Help"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView(model: model))
            w.setFrameAutosaveName("WordyHelpWindow")
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Help should not be the only thing keeping Wordy alive after the last
    /// document window closes; the app would then have no window left to make
    /// a new tab in.
    func closeIfOpen() {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
    }
}

struct HelpView: View {
    @ObservedObject var model: HelpModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(HelpTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.tab {
                    case .start: GettingStarted()
                    case .shortcuts: Shortcuts()
                    case .formats: Formats()
                    case .tips: Tips()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - Building blocks

private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct Line: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(.primary)
    }
}

private struct Key: View {
    let name: String
    let keys: String
    init(_ name: String, _ keys: String) { self.name = name; self.keys = keys }

    var body: some View {
        HStack {
            Text(name)
            Spacer(minLength: 20)
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Tabs

private struct GettingStarted: View {
    var body: some View {
        Block(title: "Just write") {
            Line("Wordy is a plain, quiet text editor. Start typing; nothing else is on screen.")
            Line("Your work is saved to a safe draft while you type, so nothing is lost if the app or your Mac crashes.")
        }
        Block(title: "Hidden controls") {
            Line("• Move the cursor to the top edge of the window: the close, minimize and zoom buttons and the file name appear.")
            Line("• Move the cursor to the bottom edge of the window: the word and character count appears.")
            Line("Move away and they fade out again.")
        }
        Block(title: "Look and feel (Appearance menu)") {
            Line("• Theme: White or Black.")
            Line("• Font: Helvetica or Typewriter.")
            Line("• Line Width: Narrow, Medium, Wide or Full Window.")
            Line("• Bigger / Smaller: change the text size (⌘+ or ⌘=, and ⌘−).")
        }
        Block(title: "Writing aids (Writing menu)") {
            Line("• Typewriter Scrolling: the line you are typing stays in the middle of the window.")
            Line("• Focus Mode: the paragraph you are in stays bright, and the text above and below it fades out gradually the further away it is. The previous paragraph dims the moment you press Enter.")
            Line("• Spelling Check: underlines misspelled words as you type, and checks text that is already on screen when you turn it on or open a draft.")
        }
        Block(title: "Tabs") {
            Line("⌘N opens a new tab. Several documents live in one window; switch with ⌃Tab or ⇧⌘[ and ⇧⌘].")
        }
    }
}

private struct Shortcuts: View {
    var body: some View {
        Block(title: "Files") {
            Key("New tab", "⌘N")
            Key("Open…", "⌘O")
            Key("Open Recent", "File menu")
            Key("Save", "⌘S")
            Key("Save As…", "⇧⌘S")
            Key("Export…", "⇧⌘E")
            Key("Print…", "⌘P")
            Key("Close tab / window", "⌘W")
            Key("Quit Wordy", "⌘Q")
        }
        Block(title: "Tabs and windows") {
            Key("Next tab", "⌃Tab   or   ⇧⌘]")
            Key("Previous tab", "⌃⇧Tab   or   ⇧⌘[")
            Key("Show all tabs", "⇧⌘\\")
            Key("Full screen", "⌃⌘F")
            Key("Minimize", "⌘M")
            Key("Hide Wordy", "⌘H")
        }
        Block(title: "Appearance") {
            Key("Bigger text", "⌘+   or   ⌘=")
            Key("Smaller text", "⌘−")
            Key("Theme, font, line width", "Appearance menu")
            Key("Typewriter, focus, spelling", "Writing menu")
        }
        Block(title: "Editing") {
            Key("Undo", "⌘Z")
            Key("Redo", "⇧⌘Z")
            Key("Cut / Copy / Paste", "⌘X  ⌘C  ⌘V")
            Key("Select all", "⌘A")
            Key("Emoji & symbols", "⌃⌘Space")
        }
        Block(title: "Find") {
            Key("Find", "⌘F")
            Key("Find next", "⌘G")
            Key("Find previous", "⇧⌘G")
            Key("Find and replace", "⌥⌘F")
            Key("Use selection for find", "⌘E")
        }
        Block(title: "Moving around") {
            Key("Start / end of line", "⌘←   ⌘→")
            Key("Start / end of document", "⌘↑   ⌘↓")
            Key("Word left / right", "⌥←   ⌥→")
            Key("Delete previous word", "⌥⌫")
            Key("Delete to start of line", "⌘⌫")
        }
        Block(title: "Help") {
            Key("Wordy Help", "⇧⌘/")
        }
    }
}

private struct Formats: View {
    var body: some View {
        Block(title: "Open (⌘O)") {
            Line("Wordy opens .txt, .md, .rtf, .html, .docx, .doc, .odt and .pdf files.")
            Line("Wordy is a plain-text editor, so formatting (bold, images, tables) is dropped when you open a Word, RTF, HTML, ODT or PDF file. Only the text is kept.")
            Line("PDFs must contain real text; scanned pages (pictures of text) cannot be read.")
        }
        Block(title: "Save (⌘S, ⇧⌘S)") {
            Line("Save always writes plain text. Opening a .docx or other rich file and pressing Save asks for a new .txt name, so your original is never overwritten.")
            Line("Text files from older programs (for example Windows-1251 Cyrillic) are detected when you open them, and Save writes them back in the same encoding. The encoding is shown next to the word count when it is not plain UTF-8 (for example Windows-1251, or UTF-8 with a BOM). Save As creates a UTF-8 file without a BOM.")
        }
        Block(title: "Export (⇧⌘E)") {
            Line("Pick the format at the bottom of the dialog: .txt, .md, .rtf, .html, .docx, .doc, .odt or .pdf.")
            Line("Exported documents use the font you have selected, in dark text on white, whichever theme you write in. PDFs are A4 with margins.")
        }
        Block(title: "Print (⌘P)") {
            Line("Opens the standard macOS print dialog; from there you can also save as PDF.")
        }
        Block(title: "Open from Finder") {
            Line("Double-click a supported file or drop it on the Wordy icon to open it in a tab.")
            Line("To make Wordy the default app for .txt files: select a .txt file in Finder, press ⌘I, choose Wordy under “Open with”, then click “Change All…”.")
        }
    }
}

private struct Tips: View {
    var body: some View {
        Block(title: "Your work is protected") {
            Line("Unsaved text is stored in a draft about a second after you stop typing. If Wordy quits or crashes, the draft comes back in a tab next time you open the app.")
            Line("Closing a tab or window with unsaved changes asks whether to save. Choose “Don't Save” to discard the draft.")
            Line("Quitting with unsaved changes also asks: save everything, or keep the drafts and quit.")
            Line("Drafts live in a folder you can open from Help › Show Saved Drafts in Finder.")
        }
        Block(title: "If the buttons are hidden") {
            Line("The window buttons only show at the top edge. You can always use ⌘W to close, ⌘M to minimize and ⌃⌘F (or View > Toggle Full Screen) for full screen.")
        }
        Block(title: "Long writing sessions") {
            Line("Try Typewriter Scrolling with Focus Mode, a Narrow line width, and the Typewriter font.")
            Line("Hover the bottom edge to check your word count without leaving the page.")
        }
        Block(title: "Remembered for you") {
            Line("Theme, font, text size, line width, the writing aids, and the window's size and position are kept between launches.")
        }
    }
}
