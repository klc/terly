import Foundation
import XCTest
@testable import SSHConfigurator

final class TerminalInputRouterTests: XCTestCase {
    @MainActor
    func testForwardsInputToOtherSynchronizedPanesOnly() {
        let router = TerminalInputRouter()
        let sourcePaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()
        var secondPaneInput: [[UInt8]] = []
        var thirdPaneInput: [[UInt8]] = []

        router.register(paneID: secondPaneID) { secondPaneInput.append($0) }
        router.register(paneID: thirdPaneID) { thirdPaneInput.append($0) }

        let forwardedCount = router.forward(
            Array("uptime\r".utf8),
            from: sourcePaneID,
            to: Set([sourcePaneID, secondPaneID, thirdPaneID])
        )

        XCTAssertEqual(forwardedCount, 2)
        XCTAssertEqual(secondPaneInput, [Array("uptime\r".utf8)])
        XCTAssertEqual(thirdPaneInput, [Array("uptime\r".utf8)])
    }

    @MainActor
    func testDoesNotForwardWhenSourceIsOutsideSynchronizationSelection() {
        let router = TerminalInputRouter()
        let sourcePaneID = UUID()
        let destinationPaneID = UUID()
        var destinationInput: [[UInt8]] = []
        router.register(paneID: destinationPaneID) { destinationInput.append($0) }

        let forwardedCount = router.forward(
            [0x0D],
            from: sourcePaneID,
            to: Set([destinationPaneID, UUID()])
        )

        XCTAssertEqual(forwardedCount, 0)
        XCTAssertTrue(destinationInput.isEmpty)
    }

    @MainActor
    func testUnregisteredPaneStopsReceivingInput() {
        let router = TerminalInputRouter()
        let sourcePaneID = UUID()
        let destinationPaneID = UUID()
        var destinationInput: [[UInt8]] = []
        router.register(paneID: destinationPaneID) { destinationInput.append($0) }
        router.unregister(paneID: destinationPaneID)

        let forwardedCount = router.forward(
            [0x03],
            from: sourcePaneID,
            to: Set([sourcePaneID, destinationPaneID])
        )

        XCTAssertEqual(forwardedCount, 0)
        XCTAssertTrue(destinationInput.isEmpty)
    }

    @MainActor
    func testDirectStartupInputTargetsOnlyRequestedPane() {
        let router = TerminalInputRouter()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        var firstInput: [[UInt8]] = []
        var secondInput: [[UInt8]] = []
        router.register(paneID: firstPaneID) { firstInput.append($0) }
        router.register(paneID: secondPaneID) { secondInput.append($0) }

        XCTAssertTrue(router.sendDirect(Array("startup\r".utf8), to: firstPaneID))

        XCTAssertEqual(firstInput, [Array("startup\r".utf8)])
        XCTAssertTrue(secondInput.isEmpty)
    }
}
