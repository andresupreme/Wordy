import Foundation

/// Keys for the settings shared by the editor and the menu commands.
/// Keeping them in one place stops the two sides from drifting apart.
enum PrefKey {
    static let theme = "theme"
    static let font = "font"
    static let fontSize = "fontSize"
    static let lineWidth = "lineWidth"
    static let typewriter = "typewriter"
    static let focusMode = "focusMode"
    /// Kept as "spellCheck" so existing settings survive the rename.
    static let spellingCheck = "spellCheck"
}
