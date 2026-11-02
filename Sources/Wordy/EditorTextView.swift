import SwiftUI
import AppKit

/// A plain-text NSTextView wrapped for SwiftUI, so we get proper theming,
/// undo/redo, the system find bar, and spell-check for free.
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    var theme: Theme
    var font: EditorFont
    var fontSize: CGFloat
    var lineWidth: LineWidth
    var typewriter: Bool
    var focusMode: Bool
    var spellingCheck: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        // Use overlay scrollers so the indicator fades out when idle instead of
        // staying permanently visible (even if the system is set to "Always").
        scrollView.scrollerStyle = .overlay
        // The scroll view now sits below the title bar / tab strip (see
        // ContentView), so no extra content insets are needed.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.postsFrameChangedNotifications = true

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        // macOS 14+ can show grey inline predictions while typing. That looks
        // like the app is guessing words, so keep it off for plain writing.
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        let c = context.coordinator
        c.scrollView = scrollView
        c.textView = textView
        NotificationCenter.default.addObserver(
            c,
            selector: #selector(Coordinator.frameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            c,
            selector: #selector(Coordinator.windowBecameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // The safe area grows when the tab bar appears, but the scroll view's
        // frame does not change, so listen for window updates as well.
        NotificationCenter.default.addObserver(
            c,
            selector: #selector(Coordinator.windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification,
            object: nil
        )
        c.apply(force: true)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            // A text view cannot spell-check existing text until it is in a
            // window, so run the first check once SwiftUI has attached it.
            c.recheckSpellingIfNeeded()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let textView = c.textView else { return }
        var force = false
        if textView.string != text {
            textView.string = text
            force = true
        }
        c.apply(force: force)
        c.recheckSpellingIfNeeded()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?

        private var lastStyleKey = ""
        private var lastFocusKey = ""
        private var lastTypewriter = false
        private var lastSpelling = false
        private var didInitialSpellCheck = false

        private var focusIsActive = false
        private var focusedParagraph: NSRange?
        private var editWasUserTyping = false
        private var editNeedsFullFocusRefresh = false

        init(_ parent: EditorTextView) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        // MARK: Applying settings

        func apply(force: Bool) {
            guard let tv = textView, let sv = scrollView else { return }
            let p = parent

            let styleKey = "\(p.theme.rawValue)|\(p.font.rawValue)|\(p.fontSize)"
            if force || styleKey != lastStyleKey {
                lastStyleKey = styleKey
                let nsFont = p.font.nsFont(size: p.fontSize)
                tv.font = nsFont
                tv.textColor = p.theme.foreground
                tv.backgroundColor = p.theme.background
                tv.insertionPointColor = p.theme.foreground
                tv.selectedTextAttributes = [
                    .backgroundColor: p.theme.selection,
                    .foregroundColor: p.theme.foreground
                ]
                tv.typingAttributes = [
                    .font: nsFont,
                    .foregroundColor: p.theme.foreground
                ]
                if let storage = tv.textStorage, storage.length > 0 {
                    let range = NSRange(location: 0, length: storage.length)
                    storage.addAttributes([.font: nsFont, .foregroundColor: p.theme.foreground], range: range)
                }
                sv.backgroundColor = p.theme.background
                lastFocusKey = "" // colors changed, so refresh Focus Mode too
            }

            updateSpelling(force: force)
            layoutInsets()

            let focusKey = "\(p.focusMode)|\(p.theme.rawValue)"
            if force || focusKey != lastFocusKey {
                lastFocusKey = focusKey
                updateFocus(fullRefresh: true)
            }

            if p.typewriter != lastTypewriter {
                lastTypewriter = p.typewriter
                if p.typewriter {
                    DispatchQueue.main.async { [weak self] in self?.centerCaret() }
                }
            }
        }

        @objc func frameChanged() {
            layoutInsets()
            if parent.typewriter { centerCaret() }
        }

        @objc func windowBecameKey() {
            recheckSpellingIfNeeded()
        }

        @objc func windowDidUpdate(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === textView?.window else { return }
            layoutInsets()
        }

        /// Existing text can only be checked after the text view is in a window.
        /// The first apply() often runs before SwiftUI attaches it.
        func recheckSpellingIfNeeded() {
            guard !didInitialSpellCheck,
                  parent.spellingCheck,
                  let tv = textView,
                  tv.window != nil else { return }
            didInitialSpellCheck = true
            tv.checkTextInDocument(nil)
        }

        /// Side margins come from the Line Width setting; in Typewriter mode the
        /// top and bottom margins are half the window so any line can sit in the middle.
        /// The ordinary top margin is smaller than before because the title bar
        /// (and tab strip) already provide space above the first line.
        func layoutInsets() {
            guard let tv = textView, let sv = scrollView else { return }

            // Keep the native overlay scroller out of the titlebar/tab bar.
            // The scroll view fills the window, but its safe area starts below
            // the chrome, so inset the scroller track by that amount.
            if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
            if !sv.autohidesScrollers { sv.autohidesScrollers = true }
            let top = sv.safeAreaInsets.top
            if abs(sv.scrollerInsets.top - top) > 0.5 {
                var insets = sv.scrollerInsets
                insets.top = top
                sv.scrollerInsets = insets
                sv.tile()
            }

            let width = sv.bounds.width
            let height = sv.bounds.height
            var horizontal: CGFloat = 40
            if let maxWidth = parent.lineWidth.maxWidth {
                horizontal = max(40, (width - maxWidth) / 2)
            }
            let vertical: CGFloat = parent.typewriter ? max(32, height / 2) : 32
            let inset = NSSize(width: horizontal.rounded(), height: vertical.rounded())
            if tv.textContainerInset != inset { tv.textContainerInset = inset }
        }

        // MARK: Spelling

        private func updateSpelling(force: Bool) {
            guard let tv = textView else { return }
            guard force || parent.spellingCheck != lastSpelling else { return }
            lastSpelling = parent.spellingCheck

            // Never rewrite the user's words; spelling check should only underline.
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isContinuousSpellCheckingEnabled = parent.spellingCheck

            if parent.spellingCheck {
                // Check text that is already on screen, not just new typing.
                // Without a window the check is a no-op, so remember that the
                // first real check still has to happen.
                didInitialSpellCheck = tv.window != nil
                tv.checkTextInDocument(nil)
            } else if let lm = tv.layoutManager, let storage = tv.textStorage, storage.length > 0 {
                didInitialSpellCheck = false
                // Drop any underlines left from the previous check.
                lm.removeTemporaryAttribute(
                    .spellingState,
                    forCharacterRange: NSRange(location: 0, length: storage.length)
                )
                tv.needsDisplay = true
            }
        }

        // MARK: Focus Mode

        /// How many lines away from the current paragraph still get their own
        /// shade. Anything further away uses the faintest shade.
        private let focusLevelCount = 40
        /// Only this many characters around the current paragraph are restyled
        /// when the cursor moves; the rest of a long document keeps the faint shade.
        private let focusWindowChars = 6000

        private var focusPaletteKey = ""
        private var focusLevels: [NSColor] = []
        private var focusFar: NSColor = .gray
        /// Characters that were last given individual shades. Everything outside
        /// this range always has the faint shade.
        private var focusWindow: NSRange?

        /// One shade per line of distance: the line right next to the current
        /// paragraph is already clearly dimmer, and the text keeps fading the
        /// further away it is, until it reaches the faint shade.
        private func ensureFocusPalette() {
            let key = parent.theme.rawValue
            guard key != focusPaletteKey || focusLevels.isEmpty else { return }
            focusPaletteKey = key
            let near = parent.theme.foreground
            let far = parent.theme.dimmed
            focusFar = far
            focusLevels = (1...focusLevelCount).map { n in
                let t = min(1.0, 0.35 + 0.65 * (1.0 - exp(-Double(n - 1) / 4.0)))
                return Coordinator.blend(near, far, CGFloat(t))
            }
        }

        private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
            guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return b }
            return NSColor(
                srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                alpha: 1
            )
        }

        /// Keeps the paragraph with the cursor bright and fades the text above
        /// and below it by distance. Moving within the same paragraph, or typing
        /// in it, is cheap; moving to another paragraph restyles the nearby lines.
        func updateFocus(fullRefresh: Bool) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)

            guard parent.focusMode else {
                if focusIsActive {
                    lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                    tv.needsDisplay = true
                }
                focusIsActive = false
                focusedParagraph = nil
                focusWindow = nil
                return
            }

            ensureFocusPalette()

            // The cursor can sit at the very end, on a brand-new empty line. That
            // empty line is its own paragraph, so everything above it dims at once,
            // right when Enter is pressed, not after the next character.
            let location = min(max(tv.selectedRange().location, 0), full.length)
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))

            // Same paragraph as before (typing in it, or moving inside it): the text
            // above and below did not change, so only keep the paragraph itself bright.
            if !fullRefresh, focusIsActive, let old = focusedParagraph,
               old.location == paragraph.location {
                if paragraph.length > 0 {
                    lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: paragraph)
                }
                focusedParagraph = paragraph
                return
            }

            let paragraphEnd = NSMaxRange(paragraph)
            let winStart = max(0, paragraph.location - focusWindowChars)
            let winEnd = min(full.length, paragraphEnd + focusWindowChars)
            let window = NSRange(location: winStart, length: max(0, winEnd - winStart))

            // Start from the faint shade: for everything on a full refresh, or just
            // for the range that was styled last time.
            if fullRefresh || !focusIsActive || focusWindow == nil {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                if full.length > 0 {
                    lm.addTemporaryAttribute(.foregroundColor, value: focusFar, forCharacterRange: full)
                }
            } else if let old = focusWindow {
                let range = clamped(old, to: full.length)
                if range.length > 0 {
                    lm.addTemporaryAttribute(.foregroundColor, value: focusFar, forCharacterRange: range)
                }
            }

            if window.length > 0 {
                lm.ensureLayout(forCharacterRange: window)
                let glyphs = lm.glyphRange(forCharacterRange: window, actualCharacterRange: nil)

                var above: [NSRange] = []
                var below: [NSRange] = []
                lm.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                    let r = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                    if NSMaxRange(r) <= paragraph.location {
                        above.append(r)
                    } else if r.location >= paragraphEnd {
                        below.append(r)
                    }
                }

                // Nearest line first, one step fainter for each line of distance.
                for (index, r) in above.reversed().prefix(focusLevelCount).enumerated() {
                    lm.addTemporaryAttribute(.foregroundColor, value: focusLevels[index], forCharacterRange: r)
                }
                for (index, r) in below.prefix(focusLevelCount).enumerated() {
                    lm.addTemporaryAttribute(.foregroundColor, value: focusLevels[index], forCharacterRange: r)
                }
            }

            if paragraph.length > 0 {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: paragraph)
            }

            focusIsActive = true
            focusedParagraph = paragraph
            focusWindow = window
            invalidateDisplay(window, in: tv, lm: lm)
        }

        private func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        private func invalidateDisplay(_ range: NSRange, in tv: NSTextView, lm: NSLayoutManager) {
            guard range.length > 0 else {
                tv.needsDisplay = true
                return
            }
            lm.invalidateDisplay(forCharacterRange: range)
            tv.needsDisplay = true
        }

        // MARK: Typewriter scrolling

        /// Scrolls so the line with the cursor sits in the vertical middle.
        func centerCaret() {
            guard let tv = textView, let sv = scrollView, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            let length = ns.length
            let location = tv.selectedRange().location

            var rect: NSRect
            if length == 0 {
                rect = lm.extraLineFragmentRect
            } else if location >= length {
                if tv.string.hasSuffix("\n") {
                    rect = lm.extraLineFragmentRect
                } else {
                    rect = lm.lineFragmentRect(forGlyphAt: max(lm.numberOfGlyphs - 1, 0), effectiveRange: nil)
                }
            } else {
                let glyph = lm.glyphIndexForCharacter(at: location)
                rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            if rect == .zero { return }

            let clip = sv.contentView
            let caretY = rect.midY + tv.textContainerOrigin.y
            var y = caretY - clip.bounds.height / 2
            y = max(0, min(y, max(0, tv.frame.height - clip.bounds.height)))
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            sv.reflectScrolledClipView(clip)
        }

        // MARK: NSTextViewDelegate

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            editWasUserTyping = true

            // Focus Mode can update paragraph-by-paragraph for ordinary typing.
            // Anything that can move paragraph boundaries (Enter, paste, deleting
            // a newline, editing before the focused paragraph) needs a full refresh.
            let replacement = replacementString ?? ""
            var full = replacement.contains("\n") || replacement.utf16.count > 1
            if !full, affectedCharRange.length > 0 {
                let ns = textView.string as NSString
                if affectedCharRange.location + affectedCharRange.length <= ns.length,
                   ns.substring(with: affectedCharRange).contains("\n") {
                    full = true
                }
            }
            if !full, let focused = focusedParagraph, affectedCharRange.location < focused.location {
                full = true
            }
            editNeedsFullFocusRefresh = full
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string

            if parent.focusMode {
                // Undo/redo and other programmatic edits do not pass through
                // shouldChangeTextIn, so give those a full refresh too.
                updateFocus(fullRefresh: editNeedsFullFocusRefresh || !editWasUserTyping)
            }
            editWasUserTyping = false
            editNeedsFullFocusRefresh = false

            if parent.typewriter { centerCaret() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if parent.focusMode {
                updateFocus(fullRefresh: false)
            }
            // Follow the caret for keyboard moves, menu commands, find, etc.
            // Mouse clicks should not yank the page around.
            if parent.typewriter, !isMouseEvent(NSApp.currentEvent) {
                centerCaret()
            }
        }

        private func isMouseEvent(_ event: NSEvent?) -> Bool {
            switch event?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return true
            default:
                return false
            }
        }
    }
}
