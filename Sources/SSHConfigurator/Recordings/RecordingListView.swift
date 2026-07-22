import SwiftUI

struct RecordingListView: View {
    @ObservedObject var library: RecordingsLibrary
    @ObservedObject var recorder: TerminalSessionRecorder
    @ObservedObject private var recordingSettings = RecordingSettings.shared

    @State private var playbackCast: CastSummary?
    @State private var renamingRecording: RecordingSummary?
    @State private var renameText = ""
    @State private var deletingRecording: RecordingSummary?
    @FocusState private var renameFieldFocused: Bool

    private var activeFolderPaths: Set<String> {
        Set(recorder.activeSessionIDs.compactMap { recorder.fileURL(for: $0)?.standardizedFileURL.path })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Recordings", systemImage: "record.circle")
                    .font(.title2.bold())
                Spacer()
                if library.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                    .disabled(library.isLoading)
            }
            .padding(20)

            Divider()

            if library.recordings.isEmpty, !library.isLoading {
                ContentUnavailableView(
                    "No recordings",
                    systemImage: "record.circle",
                    description: Text("Start recording from a terminal session. Finished recordings appear here automatically.")
                )
            } else {
                List(library.recordings) { recording in
                    recordingRow(recording)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(library.rootURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Text("Change in Settings > General")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onAppear { library.refresh() }
        .onChange(of: recordingSettings.customRootPath) { _, _ in library.refresh() }
        .sheet(item: $playbackCast) { CastPlayerView(cast: $0) }
        .alert(
            "Recording operation failed",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { library.dismissError() }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .confirmationDialog(
            "Move this recording to the Trash?",
            isPresented: Binding(
                get: { deletingRecording != nil },
                set: { if !$0 { deletingRecording = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let recording = deletingRecording { library.delete(recording) }
                deletingRecording = nil
            }
            Button("Cancel", role: .cancel) { deletingRecording = nil }
        } message: {
            Text("The recording can be recovered from the Trash until it is emptied.")
        }
    }

    @ViewBuilder
    private func recordingRow(_ recording: RecordingSummary) -> some View {
        let isActive = activeFolderPaths.contains(recording.folderURL.standardizedFileURL.path)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: recording.paneCount > 1 ? "rectangle.split.2x1" : "play.rectangle")
                    .foregroundStyle(.secondary)
                Text(recording.name).fontWeight(.medium).lineLimit(1)
                if isActive {
                    Label("Recording…", systemImage: "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                HStack(spacing: 6) {
                    if recording.paneCount == 1, let cast = recording.casts.first {
                        Button("Play", systemImage: "play.fill") { playbackCast = cast }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    actionButtons(recording, isActive: isActive)
                }
                .fixedSize()
            }

            Text(metadata(for: recording))
                .font(.caption)
                .foregroundStyle(.secondary)

            if recording.paneCount > 1 {
                DisclosureGroup("\(recording.paneCount) panes") {
                    ForEach(recording.casts) { cast in
                        HStack {
                            Image(systemName: "terminal")
                            Text(cast.name)
                            Spacer()
                            Text(castMetadata(cast))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Play", systemImage: "play.fill") { playbackCast = cast }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if recording.paneCount == 1, let cast = recording.casts.first {
                Button("Play", systemImage: "play.fill") { playbackCast = cast }
            }
            Button("Show in Finder", systemImage: "folder") { library.revealInFinder(recording) }
            Button("Rename…", systemImage: "pencil") { beginRename(recording) }
                .disabled(isActive)
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { deletingRecording = recording }
                .disabled(isActive)
        }
        .popover(
            isPresented: Binding(
                get: { renamingRecording?.id == recording.id },
                set: { if !$0, renamingRecording?.id == recording.id { renamingRecording = nil } }
            )
        ) {
            renamePopover(recording)
        }
    }

    private func actionButtons(_ recording: RecordingSummary, isActive: Bool) -> some View {
        Menu {
            Button("Show in Finder", systemImage: "folder") { library.revealInFinder(recording) }
            Button("Rename…", systemImage: "pencil") { beginRename(recording) }
                .disabled(isActive)
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { deletingRecording = recording }
                .disabled(isActive)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private func beginRename(_ recording: RecordingSummary) {
        renameText = recording.name
        renamingRecording = recording
    }

    private func renamePopover(_ recording: RecordingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Recording name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($renameFieldFocused)
                .onSubmit { finishRename(recording) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renamingRecording = nil }
                Button("Rename") { finishRename(recording) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { renameFieldFocused = true }
    }

    private func finishRename(_ recording: RecordingSummary) {
        library.rename(recording, to: renameText)
        renamingRecording = nil
    }

    private func metadata(for recording: RecordingSummary) -> String {
        let date = recording.date.formatted(date: .abbreviated, time: .shortened)
        let duration = recording.duration.map(formatDuration) ?? "—"
        let size = ByteCountFormatter.string(fromByteCount: recording.totalSize, countStyle: .file)
        let paneCount = String(localized: "\(recording.paneCount) panes")
        return "\(date) · \(duration) · \(size) · \(paneCount)"
    }

    private func castMetadata(_ cast: CastSummary) -> String {
        "\(cast.duration.map(formatDuration) ?? "—") · \(ByteCountFormatter.string(fromByteCount: cast.sizeBytes, countStyle: .file))"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
