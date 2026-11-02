import SwiftUI
import AppKit
import QuartzCore

/// Forwards everything to the window's original delegate (SwiftUI's), but asks
/// "save changes?" before the window or tab closes.
final class CloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

/// The window title, drawn by Wordy instead of the system so it can fade in and
/// out together with the window buttons. It never takes mouse clicks, so the
/// title bar can still be dragged through it.
final class ChromeTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSWindow {
    /// Height of the title bar itself, without the tab bar below it. The tab
    /// strip has to start below this, and hardcoding 28pt broke as soon as the
    /// system changed its window chrome.
    var wordyTitlebarHeight: CGFloat {
        let content = NSWindow.contentRect(
            forFrameRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable]
        )
        return max(0, frame.height - content.height)
    }
}

/// Makes the window chrome (traffic lights + title) invisible by default and
/// fades it in only while the mouse is in a thin strip at the top of the window.
/// Also: tabs, window position memory, close confirmation, bottom-edge hover.
struct WindowChrome: NSViewRepresentable {
    var state: EditorState
    /// Current theme; also painted behind the (invisible) title bar and used
    /// to color the custom tab strip.
    var theme: Theme
    var onBottomHover: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Calls back as soon as the view is actually inside a window (the window
    /// does not exist yet when SwiftUI first creates the view).
    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        let coordinator = context.coordinator
        coordinator.state = state
        coordinator.theme = theme
        coordinator.onBottomHover = onBottomHover
        view.onWindow = { window in coordinator.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.theme = theme
        context.coordinator.onBottomHover = onBottomHover
        context.coordinator.applyBackground()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        var state: EditorState?
        private var isShown = true
        private var isBottom = false
        private let zoneHeight: CGFloat = 44
        private let bottomZoneHeight: CGFloat = 40
        var theme: Theme = .white
        var onBottomHover: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        private var mouseMonitor: Any?
        private var closeGuard: CloseGuard?
        private var tabStrip: TabStripController?
        private var titleLabel: ChromeTitleLabel?
        private var hideWork: DispatchWorkItem?
        private var pollTimer: Timer?
        /// The controls appear when the cursor reaches `zoneHeight` from the top
        /// and stay until it leaves the larger `keepZoneHeight`, so they do not
        /// flicker when the cursor hovers near the edge.
        private let keepZoneHeight: CGFloat = 72
        private let fadeInDuration: TimeInterval = 0.35
        private let fadeOutDuration: TimeInterval = 0.60
        private let hideDelay: TimeInterval = 0.30

        private let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton
        ]

        func applyBackground() {
            applyChromeAppearance()
            refreshTitleLabel()
            tabStrip?.setTheme(theme)
            tabStrip?.refresh()
        }

        /// SwiftUI sometimes re-applies its own titlebar settings after we set
        /// them. Keep the appearance we want without touching private views.
        private func applyChromeAppearance() {
            guard let window = window else { return }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !(window.backgroundColor?.isEqual(theme.background) ?? false) {
                window.backgroundColor = theme.background
            }
            if !window.isOpaque { window.isOpaque = true }
        }

        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            state?.window = window
            if window.isKeyWindow { ActiveDocument.shared.activate(state) }
            installTitleLabel(in: window)

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            applyBackground()
            setChrome(visible: false, animated: false)

            // Re-apply after SwiftUI has finished configuring the window.
            DispatchQueue.main.async { [weak self] in self?.applyChromeAppearance() }

            // Tabs and remembered window position. AppKit's own window
            // restoration is off: drafts are restored explicitly, and letting
            // both run can create duplicate blank windows.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "WordyDocument"
            window.setFrameAutosaveName("WordyWindow")
            window.isRestorable = false

            // Ask "save changes?" before closing a window or tab.
            let guardDelegate = CloseGuard(original: window.delegate) { [weak self] in
                if StateRegistry.shared.isTerminating { return true }
                return self?.state?.confirmDiscardIfNeeded() ?? true
            }
            closeGuard = guardDelegate
            window.delegate = guardDelegate

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didUpdateNotification
            ]
            for name in names {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.windowChanged(name)
                }
                observers.append(token)
            }
            let closeToken = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
                guard let self else { return }
                let closingWindow = note.object as? NSWindow
                ActiveDocument.shared.deactivate(self.state)
                self.detach()
                self.state?.windowDidClose()
                // If that was the last document, do not leave an app running
                // with only the Help window and no document window to make a
                // tab in. Closing Help also lets the app quit as usual.
                let otherDocuments = StateRegistry.shared.all.contains {
                    $0.window != nil && $0.window !== closingWindow
                }
                if !otherDocuments { HelpWindow.shared.closeIfOpen() }
            }
            observers.append(closeToken)

            // Event-driven hover tracking. No polling timer, and no hiding of
            // private AppKit titlebar views by class name.
            window.acceptsMouseMovedEvents = true
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .mouseEntered, .mouseExited]
            ) { [weak self] event in
                self?.updateHoverState()
                return event
            }

            // Paint our own tab strip over the native tab bar so the tabs can
            // follow the theme's colors.
            tabStrip = TabStripController(window: window, theme: theme)
        }

        private func windowChanged(_ name: Notification.Name) {
            applyChromeAppearance()
            layoutTitleLabel()
            refreshTitleLabel()
            tabStrip?.refresh()
            switch name {
            case NSWindow.didBecomeKeyNotification:
                ActiveDocument.shared.activate(state)
                updateHoverState()
            case NSWindow.didResignKeyNotification:
                setChrome(visible: false, animated: true)
                setBottomHover(false)
            case NSWindow.didResizeNotification,
                 NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
                updateHoverState()
            default:
                break
            }
        }

        private func detach() {
            cancelPendingHide()
            pollTimer?.invalidate()
            pollTimer = nil
            titleLabel?.removeFromSuperview()
            titleLabel = nil
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            tabStrip?.uninstall()
            tabStrip = nil
            if let window, window.delegate === closeGuard {
                window.delegate = closeGuard?.original
            }
            window = nil
        }

        deinit { detach() }

        // MARK: Title label

        private func installTitleLabel(in window: NSWindow) {
            guard let themeFrame = window.contentView?.superview else { return }
            let label = ChromeTitleLabel(labelWithString: window.title)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.alphaValue = 0
            label.autoresizingMask = [.width, .minYMargin]
            themeFrame.addSubview(label)
            titleLabel = label
            layoutTitleLabel()
            refreshTitleLabel()
        }

        /// Centers the label in the title bar, clear of the window buttons.
        private func layoutTitleLabel() {
            guard let window = window, let label = titleLabel,
                  let themeFrame = label.superview else { return }
            let titlebarHeight = window.wordyTitlebarHeight
            let height: CGFloat = 17
            let side: CGFloat = 84
            let newFrame = NSRect(
                x: side,
                y: themeFrame.bounds.height - titlebarHeight / 2 - height / 2,
                width: max(0, themeFrame.bounds.width - side * 2),
                height: height
            )
            if label.frame != newFrame { label.frame = newFrame }
        }

        private func refreshTitleLabel() {
            guard let window = window, let label = titleLabel else { return }
            if label.stringValue != window.title { label.stringValue = window.title }
            label.textColor = theme.foreground.withAlphaComponent(0.6)
        }

        // MARK: Hover

        private func updateHoverState() {
            guard let window = window, window.isVisible, window.isKeyWindow else { return }
            let p = window.mouseLocationOutsideOfEventStream
            let size = window.frame.size
            let insideX = p.x >= 0 && p.x <= size.width

            let inShowZone = insideX && p.y >= size.height - zoneHeight && p.y <= size.height
            let inKeepZone = insideX && p.y >= size.height - keepZoneHeight && p.y <= size.height
            if inShowZone || (isShown && inKeepZone) {
                cancelPendingHide()
                if !isShown { setChrome(visible: true, animated: true) }
            } else if isShown {
                scheduleHide()
            }

            let inBottom = insideX && p.y >= 0 && p.y <= bottomZoneHeight
            setBottomHover(inBottom)
        }

        /// Wait a moment before fading out, so brushing past the edge does not
        /// make the controls blink.
        private func scheduleHide() {
            guard hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                self.setChrome(visible: false, animated: true)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
        }

        private func cancelPendingHide() {
            hideWork?.cancel()
            hideWork = nil
        }

        private func setBottomHover(_ value: Bool) {
            guard value != isBottom else { return }
            isBottom = value
            onBottomHover(value)
            updatePolling()
        }

        /// Mouse-moved events stop arriving once the cursor leaves the window
        /// (for example up to the menu bar), so while anything is showing, check
        /// the cursor position on a short timer as well.
        private func updatePolling() {
            let needed = isShown || isBottom
            if needed, pollTimer == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.updateHoverState()
                }
                RunLoop.main.add(timer, forMode: .common)
                pollTimer = timer
            } else if !needed {
                pollTimer?.invalidate()
                pollTimer = nil
            }
        }

        // MARK: Show / hide

        private func setChrome(visible: Bool, animated: Bool) {
            isShown = visible
            guard let window = window else { return }
            applyChromeAppearance()
            updatePolling()
            if !visible { cancelPendingHide() }

            var views: [NSView] = buttonTypes.compactMap { window.standardWindowButton($0) }
            if let titleLabel { views.append(titleLabel) }
            let target: CGFloat = visible ? 1 : 0
            if visible { views.forEach { $0.isHidden = false } }

            guard animated else {
                views.forEach {
                    $0.alphaValue = target
                    $0.isHidden = !visible
                }
                return
            }

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = visible ? fadeInDuration : fadeOutDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                views.forEach { $0.animator().alphaValue = target }
            }, completionHandler: { [weak self] in
                // Fully hidden controls must not be clickable by accident.
                if !visible, self?.isShown == false {
                    views.forEach { $0.isHidden = true }
                }
            })
        }
    }
}
