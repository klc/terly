import SwiftUI

struct SnippetPaletteView: View {
    let snippets: [Snippet]
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchIsFocused: Bool
    @State private var query = ""
    @State private var selectedSnippetID: UUID?

    private var results: [Snippet] {
        SnippetSearch.filter(snippets, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultList
            Divider()
            keyboardHelp
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            selectedSnippetID = results.first?.id
            Task { @MainActor in
                searchIsFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedSnippetID = results.first?.id
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .foregroundStyle(.secondary)
            TextField("Search snippet key or content", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchIsFocused)
                .onSubmit(insertSelected)
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
            if snippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "text.badge.plus",
                    description: Text("You can add some from the Snippets section in the sidebar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { snippet in
                            SnippetResultRow(
                                snippet: snippet,
                                isSelected: snippet.id == selectedSnippetID,
                                onSelect: { selectedSnippetID = snippet.id },
                                onInsert: { insert(snippet) }
                            )
                            .id(snippet.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedSnippetID) { _, selectedID in
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
            Label("Insert into terminal", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text("⌘S")
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
        let currentIndex = selectedSnippetID.flatMap { id in
            results.firstIndex(where: { $0.id == id })
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        selectedSnippetID = results[nextIndex].id
    }

    private func insertSelected() {
        guard let selectedSnippetID,
              let snippet = results.first(where: { $0.id == selectedSnippetID }) else {
            return
        }
        insert(snippet)
    }

    private func insert(_ snippet: Snippet) {
        onInsert(snippet.value)
        dismiss()
    }
}

private struct SnippetResultRow: View {
    let snippet: Snippet
    let isSelected: Bool
    let onSelect: () -> Void
    let onInsert: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .frame(width: 22)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(snippet.key.isEmpty ? String(localized: "(unnamed)") : snippet.key)
                            .fontWeight(.medium)
                        if snippet.isSecret {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(snippet.isSecret ? "••••••••" : snippet.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2, perform: onInsert)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

/// Adds the Cmd+S snippet palette toolbar button, palette sheet, and error
/// alert to the root view. Extracted into a modifier so the main view body
/// stays within the Swift type-checker's complexity budget.
struct SnippetPaletteSupport: ViewModifier {
    @ObservedObject var snippets: SnippetLibrary
    @ObservedObject var terminalWorkspace: TerminalWorkspaceModel
    @Binding var showingPalette: Bool
    let onInsert: (String) -> Void

    @State private var pendingValue: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Add Snippet", systemImage: "text.badge.plus") {
                        showingPalette = true
                    }
                    .keyboardShortcut(.snippetPalette)
                    .disabled(terminalWorkspace.selectedSession?.activePaneID == nil)
                }
            }
            .alert(
                "Snippet could not be saved",
                isPresented: Binding(
                    get: { snippets.errorMessage != nil },
                    set: { if !$0 { snippets.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) { snippets.dismissError() }
            } message: {
                Text(snippets.errorMessage ?? "")
            }
            .sheet(isPresented: $showingPalette, onDismiss: insertPending) {
                SnippetPaletteView(
                    snippets: snippets.snippets,
                    onInsert: { value in
                        pendingValue = value
                        showingPalette = false
                    }
                )
            }
    }

    private func insertPending() {
        guard let value = pendingValue else { return }
        pendingValue = nil
        onInsert(value)
    }
}

