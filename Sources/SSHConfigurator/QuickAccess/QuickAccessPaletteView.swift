import SwiftUI

struct QuickAccessPaletteView: View {
    let entries: [QuickAccessEntry]
    let onToggleFavorite: (UUID) -> Void
    let onRoute: (QuickAccessRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchIsFocused: Bool
    @State private var query = ""
    @State private var selectedEntryID: UUID?

    private var results: [QuickAccessSearchResult] {
        QuickAccessSearchEngine.search(query: query, entries: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultList
            Divider()
            keyboardHelp
        }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            selectedEntryID = results.first?.id
            Task { @MainActor in
                searchIsFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedEntryID = results.first?.id
        }
        .onChange(of: entries) { _, _ in
            if !results.contains(where: { $0.id == selectedEntryID }) {
                selectedEntryID = results.first?.id
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search alias, HostName, User, or group", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchIsFocused)
                .onSubmit(performPrimaryAction)
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { result in
                            QuickAccessResultRow(
                                entry: result.entry,
                                isSelected: result.id == selectedEntryID,
                                onSelect: { selectedEntryID = result.id },
                                onToggleFavorite: { onToggleFavorite(result.id) },
                                onAction: { perform($0, for: result.entry) }
                            )
                            .id(result.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedEntryID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
    }

    private var keyboardHelp: some View {
        HStack(spacing: 18) {
            Label("Select", systemImage: "arrow.up.arrow.down")
            Label("Connect", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text("⌘K")
                .font(.caption.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Button("Close (Esc)") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = selectedEntryID.flatMap { id in
            results.firstIndex(where: { $0.id == id })
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        selectedEntryID = results[nextIndex].id
    }

    private func performPrimaryAction() {
        guard let selectedEntryID,
              let entry = results.first(where: { $0.id == selectedEntryID })?.entry else {
            return
        }
        perform(.connect, for: entry)
    }

    private func perform(_ action: QuickAccessAction, for entry: QuickAccessEntry) {
        guard let route = QuickAccessActionPolicy.route(action: action, entry: entry) else {
            return
        }
        onRoute(route)
        dismiss()
    }
}

private struct QuickAccessResultRow: View {
    let entry: QuickAccessEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    let onAction: (QuickAccessAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.kind == .host ? "server.rack" : "folder.fill")
                        .frame(width: 22)
                        .foregroundStyle(entry.kind == .host ? Color.accentColor : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .fontWeight(.medium)
                        if let subtitle = entry.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let lastUsedAt = entry.lastUsedAt {
                        Text(Self.relativeDate.localizedString(for: lastUsedAt, relativeTo: Date()))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onTapGesture(count: 2) {
                onAction(.connect)
            }

            Button(action: onToggleFavorite) {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(entry.isFavorite ? .yellow : .secondary)
            .help(entry.isFavorite ? "Remove from favorites" : "Add to favorites")

            ForEach(QuickAccessActionPolicy.availableActions(for: entry), id: \.self) { action in
                Button {
                    onAction(action)
                } label: {
                    Image(systemName: icon(for: action))
                }
                .buttonStyle(.borderless)
                .help(label(for: action))
                .accessibilityLabel(label(for: action))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func icon(for action: QuickAccessAction) -> String {
        switch action {
        case .connect: "play.fill"
        case .settings: "gearshape"
        case .transfer: "arrow.left.arrow.right"
        case .diagnostics: "stethoscope"
        }
    }

    private func label(for action: QuickAccessAction) -> String {
        switch action {
        case .connect: String(localized: "Connect")
        case .settings: String(localized: "Open settings")
        case .transfer: String(localized: "Transfer files")
        case .diagnostics: String(localized: "Diagnostics")
        }
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
