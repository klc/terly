import SwiftUI

/// Single source of truth for the app's user-facing keyboard shortcuts.
///
/// Every shortcut the in-app Help guide documents is expressed here exactly
/// once — its `KeyEquivalent`, its `EventModifiers`, and a `displayString`
/// glyph derived from those two values rather than a second hand-maintained
/// literal. Call sites attach a shortcut via the `View.keyboardShortcut(_:)`
/// overload below, and `HelpCenterView` interpolates `displayString` into its
/// prose, so the bound key and the documented key can never drift apart.
///
/// The one binding that isn't a SwiftUI `.keyboardShortcut` at all is
/// terminal find: AppKit's key-equivalent dispatch reaches
/// `SwiftTermTerminalEngine.performKeyEquivalent` before SwiftUI's shortcut
/// machinery would see it, so that switch compares against
/// `AppShortcut.findInTerminal` / `.findNext` / `.findPrevious` instead of
/// bare character literals — same registry, same guarantee.
///
/// OS-convention bindings (`.defaultAction`, `.cancelAction`, `.escape`,
/// `.delete` on sheet buttons) are deliberately NOT covered here. They're
/// platform conventions, not documented app shortcuts, and pulling them into
/// this registry would add noise without reducing any drift risk.
struct AppShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    /// Glyph form used throughout the Help guide (e.g. "⇧⌘D", "⌥⌘←").
    /// Modifier order follows the standard macOS convention: ⌃⌥⇧⌘.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.glyph(for: key)
        return result
    }

    private static func glyph(for key: KeyEquivalent) -> String {
        switch key {
        case .return: return "↩"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        default: return String(key.character).uppercased()
        }
    }
}

extension AppShortcut {
    /// Quick Access (ContentView toolbar button).
    static let quickAccess = AppShortcut(key: "k", modifiers: .command)

    /// Add Snippet (SnippetPaletteSupport toolbar button).
    static let snippetPalette = AppShortcut(key: "s", modifiers: .command)

    /// Terly Help (Help menu, replacing the system Help item).
    static let help = AppShortcut(key: "/", modifiers: [.command, .shift])

    /// Split the active terminal pane vertically.
    static let splitVertically = AppShortcut(key: "d", modifiers: .command)

    /// Split the active terminal pane horizontally.
    static let splitHorizontally = AppShortcut(key: "d", modifiers: [.command, .shift])

    /// Zoom the active pane to fill the window, or restore it.
    static let zoomPane = AppShortcut(key: .return, modifiers: [.command, .shift])

    /// Directional pane navigation.
    static let paneLeft = AppShortcut(key: .leftArrow, modifiers: [.command, .option])
    static let paneRight = AppShortcut(key: .rightArrow, modifiers: [.command, .option])
    static let paneUp = AppShortcut(key: .upArrow, modifiers: [.command, .option])
    static let paneDown = AppShortcut(key: .downArrow, modifiers: [.command, .option])

    /// Terminal find: open the find bar, jump to the next/previous match.
    /// Handled by `SwiftTermTerminalEngine.performKeyEquivalent`, not
    /// `.keyboardShortcut`, because AppKit's key-equivalent dispatch claims
    /// it first.
    static let findInTerminal = AppShortcut(key: "f", modifiers: .command)
    static let findNext = AppShortcut(key: "g", modifiers: .command)
    static let findPrevious = AppShortcut(key: "g", modifiers: [.command, .shift])

    /// ⌘1…⌘9 tab selection, in order (index 0 == ⌘1).
    static let tabSelection: [AppShortcut] = (1...9).map { digit in
        AppShortcut(key: KeyEquivalent(Character(String(digit))), modifiers: .command)
    }

    /// Every registry entry, for collision checks and enumeration.
    static let all: [AppShortcut] = [
        quickAccess, snippetPalette, help,
        splitVertically, splitHorizontally, zoomPane,
        paneLeft, paneRight, paneUp, paneDown,
        findInTerminal, findNext, findPrevious,
    ] + tabSelection
}

extension View {
    /// Attaches a registry-defined shortcut, so call sites read as one
    /// semantic unit ("this button is Quick Access") instead of a bare
    /// key + modifier pair that has to be cross-referenced to know what it
    /// means.
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
