import XCTest

/// WP8 UI smoke test: a single scenario that exercises the app chrome without
/// ever touching an SSH connection (and, importantly, without writing to the
/// user's real `~/.ssh/config` — every step here is read-only: opening the
/// app just loads/displays whatever config is present, Quick Access and
/// Settings are both purely presentational overlays).
///
/// Scenario: app launches -> sidebar is visible -> ⌘K opens Quick Access ->
/// Esc closes it -> ⌘, opens Settings -> window is closed again.
final class SSHConfiguratorSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesSidebarQuickAccessAndSettingsOpenAndClose() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. App window + sidebar are visible.
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Ana pencere açılmalı")

        let quickAccessButton = app.buttons["Quick access"]
        XCTAssertTrue(quickAccessButton.waitForExistence(timeout: 10), "Toolbar'da Hızlı erişim düğmesi görünmeli")

        let sidebarConnectionsHeader = app.staticTexts["Connections"]
        XCTAssertTrue(sidebarConnectionsHeader.waitForExistence(timeout: 10), "Sidebar 'Bağlantılar' bölümü görünmeli")

        // 2. ⌘K opens Quick Access (its search field becomes visible).
        app.typeKey("k", modifierFlags: .command)
        let quickAccessSearchField = app.textFields["Search alias, HostName, User, or group"]
        XCTAssertTrue(quickAccessSearchField.waitForExistence(timeout: 10), "Hızlı erişim arama alanı açılmalı")

        // 3. Esc closes Quick Access again.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForDisappearance(of: quickAccessSearchField, timeout: 10),
            "Esc sonrası hızlı erişim kapanmalı"
        )

        // 4. Ayarlar penceresi menüden açılır. Bilinçli olarak ⌘, DEĞİL:
        //    typeKey karakteri sistemin klavye düzeni üzerinden sentezler; test dili
        //    en'e sabitlenince Türkçe-Q düzeninde "," tuşu farklı keycode'a düşüyor
        //    ve kısayol uygulamaya ulaşmıyor (gerçek kullanıcıda sorun yok, yalnız
        //    sentetik event). Menü tıklaması düzenden bağımsız.
        //    İçerik yerine pencere sayısı beklenir: Ayarlar TabView'ı son seçili
        //    sekmeyi hatırladığından sekme içeriği makine durumuna bağlıdır.
        app.menuItems["Settings…"].click()
        XCTAssertTrue(
            waitForWindowCount(of: app, toBe: 2, timeout: 10),
            "Ayarlar penceresi açılmalı"
        )

        // 5. Close the Settings window again (⌘W), leaving only the main window.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForWindowCount(of: app, toBe: 1, timeout: 10),
            "Ayarlar penceresi kapanmalı"
        )
    }

    /// Ayarlar penceresinin açılıp kapanmasını pencere sayısı üzerinden bekler.
    @MainActor
    private func waitForWindowCount(of app: XCUIApplication, toBe count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return app.windows.count == count
    }

    /// `XCTestExpectation` isn't as short-hand as `waitForExistence`, but there's
    /// no built-in "wait for disappearance" — this polls `exists` instead.
    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }
}
