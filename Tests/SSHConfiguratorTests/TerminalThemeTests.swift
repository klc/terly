import Foundation
import XCTest
@testable import SSHConfigurator

final class TerminalThemeCatalogTests: XCTestCase {
    func testEveryThemeDefinesExactly16AnsiColors() {
        for theme in TerminalThemeCatalog.all {
            XCTAssertEqual(
                theme.palette.ansi.count, 16,
                "\(theme.id) must define exactly 16 ANSI colors"
            )
        }
    }

    func testThemeIDsAreUnique() {
        let ids = TerminalThemeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Theme ids must be unique")
    }

    func testThemeDisplayNamesAreUnique() {
        let names = TerminalThemeCatalog.all.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "Theme display names must be unique")
    }

    func testSystemThemeHasNoExplicitCursorColor() {
        // The "system" theme is the one entry that intentionally defers to the
        // platform's dynamic accent color instead of a fixed cursor value.
        XCTAssertNil(TerminalThemeCatalog.system.palette.cursor)
    }

    func testNonSystemThemesDefineAnExplicitCursorColor() {
        for theme in TerminalThemeCatalog.all where theme.id != TerminalThemeCatalog.system.id {
            XCTAssertNotNil(theme.palette.cursor, "\(theme.id) should define a cursor color")
        }
    }

    func testLookupByIDReturnsTheMatchingTheme() {
        XCTAssertEqual(TerminalThemeCatalog.theme(withID: "dracula").id, "dracula")
        XCTAssertEqual(TerminalThemeCatalog.theme(withID: "nord").id, "nord")
    }

    func testLookupByUnknownIDFallsBackToSystem() {
        XCTAssertEqual(TerminalThemeCatalog.theme(withID: "does-not-exist").id, TerminalThemeCatalog.system.id)
        XCTAssertEqual(TerminalThemeCatalog.theme(withID: "").id, TerminalThemeCatalog.system.id)
    }
}

final class TerminalThemeColorTests: XCTestCase {
    func testParsesHexWithHashPrefix() {
        let color = TerminalThemeColor(hex: "#DC322F")
        XCTAssertEqual(color, TerminalThemeColor(0xDC, 0x32, 0x2F))
    }

    func testParsesHexWithoutHashPrefix() {
        let color = TerminalThemeColor(hex: "268bd2")
        XCTAssertEqual(color, TerminalThemeColor(0x26, 0x8B, 0xD2))
    }

    func testParsingIsCaseInsensitive() {
        XCTAssertEqual(TerminalThemeColor(hex: "ABCDEF"), TerminalThemeColor(hex: "abcdef"))
    }

    func testRejectsShortHex() {
        XCTAssertNil(TerminalThemeColor(hex: "#fff"))
    }

    func testRejectsLongHex() {
        XCTAssertNil(TerminalThemeColor(hex: "#0011223344"))
    }

    func testRejectsNonHexCharacters() {
        XCTAssertNil(TerminalThemeColor(hex: "zzzzzz"))
    }

    func testSwiftTermColorScalesEightBitToSixteenBit() {
        let color = TerminalThemeColor(0xFF, 0x00, 0x80)
        let swiftTermColor = color.swiftTermColor
        XCTAssertEqual(swiftTermColor.red, 0xFF * 257)
        XCTAssertEqual(swiftTermColor.green, 0)
        XCTAssertEqual(swiftTermColor.blue, 0x80 * 257)
    }

    func testNSColorRoundTripsComponents() {
        let color = TerminalThemeColor(0x11, 0x22, 0x33)
        let nsColor = color.nsColor
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Int((red * 255).rounded()), 0x11)
        XCTAssertEqual(Int((green * 255).rounded()), 0x22)
        XCTAssertEqual(Int((blue * 255).rounded()), 0x33)
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
    }
}

final class TerminalSettingsThemePersistenceTests: XCTestCase {
    // TerminalSettings is a process-wide @MainActor singleton backed by
    // UserDefaults.standard. Each test restores it to the built-in default
    // before returning so state doesn't leak into other tests or a
    // developer's real defaults; XCTestCase's own setUp/tearDown aren't
    // actor-isolated, so the reset happens inline in each @MainActor test body.

    @MainActor
    func testSettingThemeIDPersistsToUserDefaults() {
        defer { TerminalSettings.shared.themeID = TerminalThemeCatalog.system.id }

        TerminalSettings.shared.themeID = "gruvboxDark"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "terminal.themeID"), "gruvboxDark")
        XCTAssertEqual(TerminalSettings.shared.resolvedTheme.id, "gruvboxDark")
    }

    @MainActor
    func testResolvedThemeFallsBackToSystemForUnknownID() {
        defer { TerminalSettings.shared.themeID = TerminalThemeCatalog.system.id }

        TerminalSettings.shared.themeID = "not-a-real-theme"
        XCTAssertEqual(TerminalSettings.shared.resolvedTheme.id, TerminalThemeCatalog.system.id)
    }

    @MainActor
    func testResolvedThemeUpdatesWhenThemeIDChanges() {
        defer { TerminalSettings.shared.themeID = TerminalThemeCatalog.system.id }

        TerminalSettings.shared.themeID = "nord"
        XCTAssertEqual(TerminalSettings.shared.resolvedTheme.displayName, "Nord")

        TerminalSettings.shared.themeID = "dracula"
        XCTAssertEqual(TerminalSettings.shared.resolvedTheme.displayName, "Dracula")
    }
}
