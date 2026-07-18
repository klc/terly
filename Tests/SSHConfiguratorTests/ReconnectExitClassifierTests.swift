import XCTest
@testable import SSHConfigurator

final class ReconnectExitClassifierTests: XCTestCase {
    func testUnexpectedWhenPaneStillPresentAndNotUserClosed() {
        XCTAssertTrue(
            ReconnectExitClassifier.isUnexpectedDisconnect(
                paneStillPresent: true,
                userInitiatedClose: false
            )
        )
    }

    func testNotUnexpectedWhenUserClosedThePaneEvenIfItWasStillPresent() {
        XCTAssertFalse(
            ReconnectExitClassifier.isUnexpectedDisconnect(
                paneStillPresent: true,
                userInitiatedClose: true
            )
        )
    }

    func testNotUnexpectedWhenThePaneIsAlreadyGoneRegardlessOfTheCloseFlag() {
        XCTAssertFalse(
            ReconnectExitClassifier.isUnexpectedDisconnect(
                paneStillPresent: false,
                userInitiatedClose: false
            )
        )
        XCTAssertFalse(
            ReconnectExitClassifier.isUnexpectedDisconnect(
                paneStillPresent: false,
                userInitiatedClose: true
            )
        )
    }

    /// A plain `exit` typed into the remote shell (or the remote side hanging
    /// up) looks identical to any other still-present exit here — WP7
    /// deliberately doesn't special-case exit code 0.
    func testCleanExitWithoutUserActionStillCountsAsUnexpected() {
        XCTAssertTrue(
            ReconnectExitClassifier.isUnexpectedDisconnect(
                paneStillPresent: true,
                userInitiatedClose: false
            )
        )
    }
}
