import Combine
import Foundation

@MainActor
final class CastPlaybackEngine: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published var speed: Double = 1
    @Published private(set) var isFinished = false

    var feedText: ((String) -> Void)?
    var resetTerminal: (() -> Void)?

    private let events: [AsciicastEvent]
    private let sleeper: (Double) async throws -> Void
    private var nextEventIndex = 0
    private var playbackTask: Task<Void, Never>?

    var duration: TimeInterval { events.last?.time ?? 0 }

    init(
        events: [AsciicastEvent],
        sleeper: @escaping (Double) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.events = events.filter { $0.kind == "o" }
        self.sleeper = sleeper
    }

    func play() {
        guard !isPlaying else { return }
        if isFinished {
            resetTerminal?()
            currentTime = 0
            nextEventIndex = 0
            isFinished = false
        }
        guard nextEventIndex < events.count else {
            isFinished = true
            return
        }

        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.nextEventIndex < self.events.count {
                let event = self.events[self.nextEventIndex]
                let gap = min(max(0, event.time - self.currentTime), 2) / max(self.speed, 0.1)
                if gap > 0 {
                    do { try await self.sleeper(gap) } catch { break }
                }
                guard !Task.isCancelled else { break }

                var text = event.data
                var lastTime = event.time
                self.nextEventIndex += 1
                while self.nextEventIndex < self.events.count {
                    let next = self.events[self.nextEventIndex]
                    guard next.time - lastTime < 0.016 else { break }
                    text += next.data
                    lastTime = next.time
                    self.nextEventIndex += 1
                }
                self.feedText?(text)
                self.currentTime = lastTime
            }

            guard !Task.isCancelled else { return }
            self.isPlaying = false
            self.playbackTask = nil
            if self.nextEventIndex >= self.events.count {
                self.currentTime = self.duration
                self.isFinished = true
            }
        }
    }

    func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func seek(to requestedTime: TimeInterval) {
        let target = min(max(0, requestedTime), duration)
        let shouldResume = isPlaying
        pause()
        resetTerminal?()

        var chunk = ""
        var chunkBytes = 0
        nextEventIndex = 0
        for (index, event) in events.enumerated() where event.time <= target {
            let bytes = event.data.utf8.count
            if chunkBytes + bytes > 256 * 1024, !chunk.isEmpty {
                feedText?(chunk)
                chunk = ""
                chunkBytes = 0
            }
            chunk += event.data
            chunkBytes += bytes
            nextEventIndex = index + 1
        }
        if !chunk.isEmpty { feedText?(chunk) }
        currentTime = target
        isFinished = nextEventIndex >= events.count && !events.isEmpty && target >= duration
        if shouldResume, !isFinished { play() }
    }

    func teardown() {
        pause()
        feedText = nil
        resetTerminal = nil
    }
}
