import XCTest
@testable import SSHConfigurator

@MainActor
final class CastPlaybackEngineTests: XCTestCase {
    func testPlaybackOrderBatchingAndDelays() async {
        var delays: [Double] = []
        var output: [String] = []
        let engine = CastPlaybackEngine(
            events: [event(0.5, "a"), event(0.51, "b"), event(1.5, "c"), AsciicastEvent(time: 2, kind: "i", data: "ignored")],
            sleeper: { delays.append($0); await Task.yield() }
        )
        engine.feedText = { output.append($0) }

        engine.play()
        await waitUntil { engine.isFinished }
        XCTAssertEqual(output, ["ab", "c"])
        XCTAssertEqual(delays.count, 2)
        XCTAssertEqual(delays[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(delays[1], 0.99, accuracy: 0.0001)
    }

    func testSpeedAndIdleCapAreAppliedPerIteration() async {
        var delays: [Double] = []
        var engine: CastPlaybackEngine!
        engine = CastPlaybackEngine(events: [event(2, "a"), event(62, "b")]) { delay in
            delays.append(delay)
            if delays.count == 1 { await MainActor.run { engine.speed = 2 } }
            await Task.yield()
        }
        engine.play()
        await waitUntil { engine.isFinished }
        XCTAssertEqual(delays, [2, 1])
    }

    func testSeekFeedsPrefixAndResumesWhenPlaying() async {
        var output: [String] = []
        var resetCount = 0
        let engine = CastPlaybackEngine(events: [event(1, "a"), event(2, "b"), event(3, "c")]) { _ in
            try await Task.sleep(for: .seconds(60))
        }
        engine.feedText = { output.append($0) }
        engine.resetTerminal = { resetCount += 1 }
        engine.play()
        await Task.yield()
        engine.seek(to: 2)

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(output, ["ab"])
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
    }

    func testPauseAndReplayAfterFinish() async {
        var output = ""
        var resets = 0
        let engine = CastPlaybackEngine(events: [event(0, "x")]) { _ in }
        engine.feedText = { output += $0 }
        engine.resetTerminal = { resets += 1 }
        engine.play()
        await waitUntil { engine.isFinished }
        engine.play()
        await waitUntil { engine.isFinished && output == "xx" }
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(output, "xx")
    }

    private func event(_ time: Double, _ data: String) -> AsciicastEvent {
        AsciicastEvent(time: time, kind: "o", data: data)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }
}
