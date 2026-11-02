import SwiftUI
import AppKit

/// One tab as drawn by Wordy's custom strip. Each tab is still a real
/// NSWindow in the same NSWindowTabGroup, so window management stays native.
struct WordyTabItem: Equatable {
    let window: NSWindow
    let title: String
    let isSelected: Bool
}

/// Colors for the custom tab strip. The native tab bar cannot be tinted
/// through public AppKit API, so we paint our own strip over it.
struct WordyTabPalette {
    let bar: NSColor
    let active: NSColor
    let hover: NSColor
    let separator: NSColor
    let activeText: NSColor
    let inactiveText: NSColor
    let close: NSColor

    init(theme: Theme) {
        bar = theme.background
        active = theme.tabActive
        hover = theme.tabHover
        separator = theme.tabSeparator
        activeText = theme.foreground
        inactiveText = theme.foreground.withAlphaComponent(0.62)
        close = theme.foreground.withAlphaComponent(0.70)
    }
}

/// Draws tabs and handles selecting, closing, and creating them. The view is
/// installed in the window's theme frame, directly over AppKit's native tab
/// bar, so the tab bar itself keeps its normal geometry and behavior.
final class TabStripView: NSView {
    var items: [WordyTabItem] = [] {
        didSet {
            if items.map(\.window) != oldValue.map(\.window) {
                hoveredIndex = nil
                hoveredClose = false
            }
            needsDisplay = true
        }
    }
    var palette = WordyTabPalette(theme: .white) {
        didSet { needsDisplay = true }
    }

    var onSelect: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?
    var onNewTab: (() -> Void)?

    private var hoveredIndex: Int?
    private var hoveredClose = false
    private var trackingArea: NSTrackingArea?

    private let plusWidth: CGFloat = 28
    private let closeSize: CGFloat = 18

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private func tabRects() -> [NSRect] {
        guard !items.isEmpty else { return [] }
        let available = max(0, bounds.width - plusWidth)
        let width = available / CGFloat(items.count)
        return items.indices.map { index in
            NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }

    private var plusRect: NSRect {
        NSRect(x: max(0, bounds.width - plusWidth), y: 0,
               width: plusWidth, height: bounds.height)
    }

    private func closeRect(for index: Int) -> NSRect {
        let rect = tabRects()[index]
        return NSRect(x: rect.maxX - closeSize - 8,
                      y: (rect.height - closeSize) / 2,
                      width: closeSize, height: closeSize)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        for (index, rect) in tabRects().enumerated() where rect.contains(point) {
            return index
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        palette.bar.setFill()
        dirtyRect.fill()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let rects = tabRects()
        for (index, item) in items.enumerated() {
            let rect = rects[index]

            if item.isSelected {
                palette.active.setFill()
                rect.fill()
            } else if hoveredIndex == index {
                palette.hover.setFill()
                rect.fill()
            }

            let showClose = hoveredIndex == index
            drawTitle(item, in: rect, showClose: showClose)
            if showClose {
                drawCloseButton(for: index)
            }
        }

        drawPlusButton()
    }

    private func drawTitle(_ item: WordyTabItem, in rect: NSRect, showClose: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: item.isSelected ? palette.activeText : palette.inactiveText,
            .paragraphStyle: paragraph
        ]
        let title = item.title as NSString
        let height = title.size(withAttributes: attributes).height
        let rightReserve: CGFloat = showClose ? closeSize + 8 : 8
        let textRect = NSRect(x: rect.minX + 10,
                              y: (rect.height - height) / 2,
                              width: max(0, rect.width - 10 - rightReserve),
                              height: height + 2)
        title.draw(in: textRect, withAttributes: attributes)
    }

    private func drawCloseButton(for index: Int) {
        let rect = closeRect(for: index)
        if hoveredClose {
            palette.separator.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        let inset: CGFloat = 5.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        (hoveredClose ? palette.activeText : palette.close).setStroke()
        path.stroke()
    }

    private func drawPlusButton() {
        let rect = plusRect

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .light),
            .foregroundColor: palette.inactiveText
        ]
        let plus = "+" as NSString
        let size = plus.size(withAttributes: attributes)
        plus.draw(at: NSPoint(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2),
                  withAttributes: attributes)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // The writing area underneath uses an I-beam cursor and extends behind
    // this strip, so the strip has to claim the cursor itself.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil || hoveredClose {
            hoveredIndex = nil
            hoveredClose = false
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if plusRect.contains(point) {
            onNewTab?()
            return
        }

        if let index = tabIndex(at: point) {
            if closeRect(for: index).contains(point) {
                onClose?(items[index].window)
            } else {
                onSelect?(items[index].window)
            }
            return
        }

        // Empty strip: behave like the native tab bar and drag the window.
        window?.performDrag(with: event)
    }

    private func updateHover(at point: NSPoint) {
        let index = tabIndex(at: point)
        let close = index.map { closeRect(for: $0).contains(point) } ?? false
        if index != hoveredIndex || close != hoveredClose {
            hoveredIndex = index
            hoveredClose = close
            needsDisplay = true
        }
    }
}

/// Keeps the custom strip in sync with a window's native tab group.
final class TabStripController {
    private let view = TabStripView()
    private weak var window: NSWindow?
    private weak var themeFrame: NSView?
    private var theme: Theme

    private var groupObservation: NSKeyValueObservation?
    private var selectionObservation: NSKeyValueObservation?
    private var titleObservations: [NSKeyValueObservation] = []
    private var observedWindowIDs: [ObjectIdentifier] = []

    init(window: NSWindow, theme: Theme) {
        self.window = window
        self.theme = theme
        view.palette = WordyTabPalette(theme: theme)
        view.onSelect = { [weak self] tab in self?.select(tab) }
        view.onClose = { tab in tab.performClose(nil) }
        view.onNewTab = { OpenRouter.shared.newTab() }
        install()
    }

    deinit { uninstall() }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        view.palette = WordyTabPalette(theme: theme)
        view.needsDisplay = true
    }

    func refresh() {
        guard let window,
              let themeFrame = themeFrame ?? window.contentView?.superview else { return }
        self.themeFrame = themeFrame

        guard let group = window.tabGroup else {
            view.isHidden = true
            return
        }
        let windows = group.windows
        observeTitles(of: windows)

        let topInset = window.contentView?.safeAreaInsets.top ?? 0
        let titlebarHeight = window.wordyTitlebarHeight
        let barHeight = max(0, topInset - titlebarHeight)
        let fullScreen = window.styleMask.contains(.fullScreen)
        let visible = windows.count > 1
            && !fullScreen
            && topInset > titlebarHeight + 4
            && barHeight > 8

        view.isHidden = !visible
        guard visible else { return }

        // The tab bar is the part of the safe-area top that is not the title
        // bar. Deriving both means a future macOS chrome change does not leave
        // the strip a few points too high or too low.
        // The strip reaches 1pt into the writing area so that no hairline from
        // the native tab bar can show through underneath it.
        let frame = NSRect(x: 0,
                           y: window.contentLayoutRect.maxY - 1,
                           width: themeFrame.bounds.width,
                           height: barHeight + 1)
        if view.frame != frame { view.frame = frame }

        // refresh() runs on every window update. Assigning items always marks
        // the strip for repaint, so only touch it when something visible changed.
        let newItems = windows.map { tabWindow in
            WordyTabItem(
                window: tabWindow,
                title: tabWindow.title,
                isSelected: tabWindow === group.selectedWindow
            )
        }
        if newItems != view.items { view.items = newItems }

        // Keep the strip above the native tab bar even if AppKit reorders the
        // titlebar views while tabs are added or removed.
        view.layer?.zPosition = 1_000
        if themeFrame.subviews.last !== view {
            themeFrame.addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    private func install() {
        guard let window, let themeFrame = window.contentView?.superview else { return }
        self.themeFrame = themeFrame
        view.wantsLayer = true
        view.layer?.zPosition = 1_000
        themeFrame.addSubview(view, positioned: .above, relativeTo: nil)

        guard let group = window.tabGroup else { return }
        groupObservation = group.observe(\.windows, options: [.initial, .new]) { [weak self] _, _ in
            self?.refresh()
        }
        selectionObservation = group.observe(\.selectedWindow, options: [.initial, .new]) { [weak self] _, _ in
            self?.refresh()
        }
        refresh()
    }

    func uninstall() {
        groupObservation = nil
        selectionObservation = nil
        titleObservations.removeAll()
        observedWindowIDs.removeAll()
        view.removeFromSuperview()
        themeFrame = nil
    }

    private func select(_ tab: NSWindow) {
        guard let window else { return }
        window.tabGroup?.selectedWindow = tab
        tab.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeTitles(of windows: [NSWindow]) {
        let ids = windows.map(ObjectIdentifier.init)
        guard ids != observedWindowIDs else { return }
        titleObservations.removeAll()
        observedWindowIDs = ids
        titleObservations = windows.map { tabWindow in
            tabWindow.observe(\.title, options: [.new]) { [weak self] _, _ in
                // A title change can arrive while AppKit is in the middle of a
                // layout pass; refresh on the next run loop turn.
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }
}
