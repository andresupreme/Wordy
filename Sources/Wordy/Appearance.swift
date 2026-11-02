import SwiftUI
import AppKit

enum Theme: String, CaseIterable, Identifiable {
    case white, black
    var id: String { rawValue }

    var title: String { self == .white ? "White" : "Black" }
    // Black theme is a soft charcoal rather than pure black, with slightly dimmed text.
    var background: NSColor { self == .white ? .white : NSColor(white: 0.16, alpha: 1) }
    var foreground: NSColor { self == .white ? .black : NSColor(white: 0.90, alpha: 1) }
    var selection: NSColor {
        self == .white ? NSColor(white: 0.80, alpha: 1) : NSColor(white: 0.34, alpha: 1)
    }
    /// Text color for everything except the current paragraph in Focus Mode.
    var dimmed: NSColor {
        self == .white ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.45, alpha: 1)
    }

    // The native tab bar cannot be tinted through public AppKit API, so Wordy
    // draws its own tab strip. Inactive tabs use the theme background exactly;
    // the selected tab is a little darker so it stands out.
    var tabActive: NSColor {
        self == .white ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.125, alpha: 1)
    }
    var tabHover: NSColor {
        self == .white ? NSColor(white: 0.965, alpha: 1) : NSColor(white: 0.195, alpha: 1)
    }
    var tabSeparator: NSColor {
        self == .white ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.23, alpha: 1)
    }

    var swiftUIBackground: Color { Color(nsColor: background) }
    var scheme: ColorScheme { self == .white ? .light : .dark }
}

/// Maximum width of the text column. Wider windows get side margins.
enum LineWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .full: return "Full Window"
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .narrow: return 560
        case .medium: return 700
        case .wide: return 900
        case .full: return nil
        }
    }
}

enum EditorFont: String, CaseIterable, Identifiable {
    case helvetica, typewriter
    var id: String { rawValue }

    var title: String { self == .helvetica ? "Helvetica" : "Typewriter" }

    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .helvetica:
            return NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        case .typewriter:
            // Courier is monospaced, like a real typewriter. (American Typewriter
            // has the look but not the even spacing.)
            return NSFont(name: "Courier New", size: size)
                ?? NSFont(name: "Courier", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
