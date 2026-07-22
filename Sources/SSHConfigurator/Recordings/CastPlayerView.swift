import SwiftUI

struct CastPlayerView: View {
    let cast: CastSummary

    @Environment(\.dismiss) private var dismiss
    @State private var file: AsciicastFile?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let file {
                LoadedCastPlayerView(
                    file: file,
                    title: cast.name,
                    onRequestClose: { dismiss() }
                )
            } else if let loadError {
                ContentUnavailableView(
                    "Recording could not be opened",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading recording…")
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .overlay(alignment: .topTrailing) {
            if file == nil {
                PlayerCloseButton(action: { dismiss() })
                    .padding(12)
            }
        }
        .task(id: cast.url) {
            file = nil
            loadError = nil
            do {
                file = try await Task.detached(priority: .userInitiated) {
                    try AsciicastFile.load(url: cast.url)
                }.value
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct LoadedCastPlayerView: View {
    let title: String
    let onRequestClose: () -> Void
    @StateObject private var engine: CastPlaybackEngine
    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    init(file: AsciicastFile, title: String, onRequestClose: @escaping () -> Void) {
        self.title = title
        self.onRequestClose = onRequestClose
        _engine = StateObject(wrappedValue: CastPlaybackEngine(events: file.events))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("asciicast v2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PlayerCloseButton(action: onRequestClose)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
            PlaybackTerminalSurface(engine: engine, onRequestClose: onRequestClose)
                .background(Color(nsColor: TerminalSettings.shared.resolvedTheme.palette.background.nsColor))
            Divider()

            HStack(spacing: 14) {
                Button {
                    engine.isPlaying ? engine.pause() : engine.play()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])
                .help(engine.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : engine.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(engine.duration, 0.001),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubTime = engine.currentTime
                        } else {
                            engine.seek(to: scrubTime)
                        }
                    }
                )

                Text("\(format(isScrubbing ? scrubTime : engine.currentTime)) / \(format(engine.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 88, alignment: .trailing)

                Picker("Speed", selection: $engine.speed) {
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            .padding(14)
        }
        .onAppear { engine.play() }
        .onDisappear { engine.teardown() }
    }

    private func format(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .keyboardShortcut(.cancelAction)
            .help("Close")
    }
}
