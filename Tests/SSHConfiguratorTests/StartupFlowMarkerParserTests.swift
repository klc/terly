import XCTest
@testable import SSHConfigurator

final class StartupFlowMarkerParserTests: XCTestCase {
    func testParsesSplitMarkersAndKeepsNormalTerminalOutput() {
        var parser = StartupFlowMarkerParser(prefix: "RUN")

        let first = parser.process(Array("hello\u{1e}RUN|runn".utf8)[...])
        let second = parser.process(Array("ing|2\u{1f}world".utf8)[...])

        XCTAssertEqual(String(bytes: first.visibleBytes, encoding: .utf8), "hello")
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(String(bytes: second.visibleBytes, encoding: .utf8), "world")
        XCTAssertEqual(second.events, [.running(stepIndex: 2)])
    }

    func testParsesCompletionAndFailureWithExactStep() {
        var parser = StartupFlowMarkerParser(prefix: "RUN")
        let bytes = Array("\u{1e}RUN|completed\u{1f}\u{1e}RUN|failed|1|17\u{1f}".utf8)

        let result = parser.process(bytes[...])

        XCTAssertTrue(result.visibleBytes.isEmpty)
        XCTAssertEqual(result.events, [.completed, .failed(stepIndex: 1, exitCode: 17)])
    }

    func testUnknownRecordSeparatorPayloadRemainsVisible() {
        var parser = StartupFlowMarkerParser(prefix: "RUN")
        let bytes = Array("a\u{1e}OTHER|completed\u{1f}b".utf8)

        let result = parser.process(bytes[...])

        XCTAssertEqual(result.visibleBytes, bytes)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testOversizedMarkerIsFlushedVisiblyAndParsingContinues() {
        var parser = StartupFlowMarkerParser(prefix: "RUN", maxMarkerLength: 32)
        let oversized = "\u{1e}" + String(repeating: "x", count: 33) + "visible-tail"

        let result = parser.process(Array(oversized.utf8)[...])
        let next = parser.process(Array("-next".utf8)[...])

        XCTAssertEqual(String(bytes: result.visibleBytes, encoding: .utf8), oversized)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(String(bytes: next.visibleBytes, encoding: .utf8), "-next")
    }

    func testFinalizeReturnsIncompleteMarkerBytesExactlyOnce() {
        var parser = StartupFlowMarkerParser(prefix: "RUN")
        let pending = Array("\u{1e}RUN|runn".utf8)

        let partial = parser.process(pending[...])

        XCTAssertTrue(partial.visibleBytes.isEmpty)
        XCTAssertTrue(partial.events.isEmpty)
        XCTAssertEqual(parser.finalize(), pending)
        XCTAssertTrue(parser.finalize().isEmpty)
    }

    func testRecognizedMarkerPrefixNeverLeaksIntoVisibleOutput() {
        var parser = StartupFlowMarkerParser(prefix: "SECRET_MARKER_PREFIX")
        let input = Array("before\u{1e}SECRET_MARKER_PREFIX|completed\u{1f}after".utf8)

        let result = parser.process(input[...])

        XCTAssertEqual(String(bytes: result.visibleBytes, encoding: .utf8), "beforeafter")
        XCTAssertEqual(result.events, [.completed])
    }
}
