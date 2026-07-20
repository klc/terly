import SwiftUI
import XCTest
@testable import SSHConfigurator

final class AppShortcutTests: XCTestCase {
    func testDisplayStringRendersExpectedGlyphs() {
        XCTAssertEqual(AppShortcut.quickAccess.displayString, "⌘K")
        XCTAssertEqual(AppShortcut.splitHorizontally.displayString, "⇧⌘D")
        XCTAssertEqual(AppShortcut.paneLeft.displayString, "⌥⌘←")
        XCTAssertEqual(AppShortcut.tabSelection[0].displayString, "⌘1")
    }

    func testNoTwoRegistryEntriesShareTheSameKeyAndModifierCombination() {
        var seen = Set<String>()
        for shortcut in AppShortcut.all {
            let signature = "\(shortcut.key.character)|\(shortcut.modifiers.rawValue)"
            XCTAssertTrue(
                seen.insert(signature).inserted,
                "Duplicate shortcut binding: \(shortcut.displayString)"
            )
        }
    }

    /// Terminal find isn't a SwiftUI `.keyboardShortcut` at all — AppKit's
    /// key-equivalent dispatch claims it first (see
    /// `SwiftTermTerminalEngine.performKeyEquivalent`). This mirrors that
    /// method's exact matching logic (lowercased character + shift flag)
    /// against the registry entries it consults, so the two cannot silently
    /// drift apart.
    func testFindEntriesMatchWhatPerformKeyEquivalentDispatchesOn() {
        func matches(_ shortcut: AppShortcut, key: String, shift: Bool) -> Bool {
            String(shortcut.key.character) == key && shortcut.modifiers.contains(.shift) == shift
        }

        XCTAssertTrue(matches(.findInTerminal, key: "f", shift: false))
        XCTAssertFalse(matches(.findInTerminal, key: "f", shift: true))

        XCTAssertTrue(matches(.findNext, key: "g", shift: false))
        XCTAssertFalse(matches(.findNext, key: "g", shift: true))

        XCTAssertTrue(matches(.findPrevious, key: "g", shift: true))
        XCTAssertFalse(matches(.findPrevious, key: "g", shift: false))
    }
}
