import AppKit
import MetalKit
import XCTest
@testable import SSHConfigurator

final class PaneMouseActivationTests: XCTestCase {
    @MainActor
    func testMetalRendererHitIsRoutedToTerminalForMouseActivation() {
        let terminal = SynchronizableLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let renderer = MTKView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer, positioned: .above, relativeTo: nil)

        XCTAssertTrue(terminal.hitTest(NSPoint(x: 200, y: 150)) === terminal)
    }

    @MainActor
    func testNonMetalChildKeepsItsNativeHitTarget() {
        let terminal = SynchronizableLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        terminal.addSubview(child, positioned: .above, relativeTo: nil)

        XCTAssertTrue(terminal.hitTest(NSPoint(x: 50, y: 50)) === child)
    }
}
