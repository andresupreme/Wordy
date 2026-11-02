import SwiftUI

struct ContentView: View {
    @StateObject private var state = EditorState()
    @AppStorage(PrefKey.theme) private var themeRaw = Theme.white.rawValue
    @AppStorage(PrefKey.font) private var fontRaw = EditorFont.helvetica.rawValue
    @AppStorage(PrefKey.fontSize) private var fontSize = 16.0
    @AppStorage(PrefKey.lineWidth) private var lineWidthRaw = LineWidth.medium.rawValue
    @AppStorage(PrefKey.typewriter) private var typewriter = false
    @AppStorage(PrefKey.focusMode) private var focusMode = false
    @AppStorage(PrefKey.spellingCheck) private var spellingCheck = false

    /// True while the cursor is at the bottom edge of the window.
    @State private var showStats = false

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .white }
    private var font: EditorFont { EditorFont(rawValue: fontRaw) ?? .helvetica }
    private var lineWidth: LineWidth { LineWidth(rawValue: lineWidthRaw) ?? .medium }

    var body: some View {
        EditorTextView(
            text: $state.text,
            theme: theme,
            font: font,
            fontSize: fontSize,
            lineWidth: lineWidth,
            typewriter: typewriter,
            focusMode: focusMode,
            spellingCheck: spellingCheck
        )
        // The editor starts below the title bar / tab strip, so scrolled text is
        // cut off at the bottom edge of the chrome instead of running behind it.
        // The window itself is painted in the theme color, so the band above
        // still looks seamless.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .background(theme.swiftUIBackground.ignoresSafeArea())
        .background(
            WindowChrome(
                state: state,
                theme: theme,
                onBottomHover: { showStats = $0 }
            )
        )
        .overlay(alignment: .bottom) {
            if showStats {
                StatsLabel(text: state.text, color: Color(nsColor: theme.foreground), encoding: state.encodingNote)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showStats)
        .preferredColorScheme(theme.scheme)
        .navigationTitle(state.displayName + (state.isDirty ? " — Edited" : ""))
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { OpenRouter.shared.claim(for: state) }
    }
}

/// Word and character count, shown only while the cursor rests at the bottom edge.
private struct StatsLabel: View {
    let text: String
    let color: Color
    /// Set only for files that are not UTF-8.
    let encoding: String?

    var body: some View {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let extra = encoding.map { "  ·  \($0)" } ?? ""
        Text("\(words) words  ·  \(text.count) characters\(extra)")
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(color.opacity(0.6))
            .padding(.bottom, 14)
    }
}
