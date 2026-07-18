import Combine
import SwiftUI

@MainActor
final class RemoteFileBrowserModel: ObservableObject {
    @Published private(set) var snapshot: RemoteDirectorySnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var manualPath: String
    @Published var selectedFileID: RemoteFileEntry.ID?
    @Published private(set) var isCreatingDirectory = false
    @Published private(set) var createError: String?
    @Published private(set) var isRenaming = false
    @Published private(set) var renameError: String?
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteError: String?

    let alias: String
    private let service: SFTPDirectoryListingService
    private var loadTask: Task<Void, Never>?

    init(
        alias: String,
        initialPath: String,
        service: SFTPDirectoryListingService = SFTPDirectoryListingService()
    ) {
        self.alias = alias
        manualPath = initialPath
        self.service = service
    }

    var breadcrumbs: [RemotePathBreadcrumb] {
        guard let path = snapshot?.path else { return [] }
        var result = [RemotePathBreadcrumb(label: "/", path: "/")]
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/\(component)"
            result.append(RemotePathBreadcrumb(label: String(component), path: accumulated))
        }
        return result
    }

    var selectedFile: RemoteFileEntry? {
        guard let selectedFileID else { return nil }
        return snapshot?.entries.first { $0.id == selectedFileID }
    }

    func loadInitialPath() {
        load(path: manualPath.isEmpty ? "." : manualPath)
    }

    func loadHome() {
        load(path: ".")
    }

    func loadParent() {
        guard let path = snapshot?.path else { return }
        load(path: RemotePath.parent(of: path))
    }

    func refresh() {
        load(path: snapshot?.path ?? manualPath)
    }

    func open(_ entry: RemoteFileEntry) {
        guard entry.kind == .directory else {
            selectedFileID = entry.id
            return
        }
        load(path: entry.path)
    }

    func loadManualPath() {
        load(path: manualPath)
    }

    func load(path: String) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        selectedFileID = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await service.listDirectory(alias: alias, path: path)
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                manualPath = snapshot.path
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Creates a directory named `name` inside the current directory and navigates into it.
    func createDirectory(name: String) {
        guard RemoteFileNameValidator.isValid(name), let currentPath = snapshot?.path else {
            createError = RemoteFileBrowserError.invalidName.localizedDescription
            return
        }
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPath = RemotePath.appending(folderName, to: currentPath)

        isCreatingDirectory = true
        createError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.createDirectory(alias: alias, path: newPath)
                // Navigate into the newly created folder.
                self.load(path: newPath)
            } catch {
                self.createError = error.localizedDescription
            }
            self.isCreatingDirectory = false
        }
    }

    func clearCreateError() {
        createError = nil
    }

    /// Renames `entry` to `newName` (a single path component, not a full path) within
    /// its current parent directory, then refreshes the listing.
    func rename(entry: RemoteFileEntry, to newName: String) {
        guard RemoteFileNameValidator.isValid(newName), let currentPath = snapshot?.path else {
            renameError = RemoteFileBrowserError.invalidName.localizedDescription
            return
        }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationPath = RemotePath.appending(trimmedName, to: currentPath)
        guard destinationPath != entry.path else { return }

        isRenaming = true
        renameError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.rename(alias: alias, from: entry.path, to: destinationPath)
                self.load(path: currentPath)
            } catch {
                self.renameError = error.localizedDescription
            }
            self.isRenaming = false
        }
    }

    func clearRenameError() {
        renameError = nil
    }

    /// Deletes `entry` (file/symlink via `rm`, empty directory via `rmdir` — see
    /// `SFTPDirectoryListingService.delete`) then refreshes the listing. Callers are
    /// expected to have already shown a confirmation dialog; this method does not ask again.
    func delete(entry: RemoteFileEntry) {
        guard let currentPath = snapshot?.path else { return }

        isDeleting = true
        deleteError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.delete(alias: alias, path: entry.path, kind: entry.kind)
                self.load(path: currentPath)
            } catch {
                self.deleteError = error.localizedDescription
            }
            self.isDeleting = false
        }
    }

    func clearDeleteError() {
        deleteError = nil
    }
}

struct RemoteFileBrowserSheet: View {
    let mode: RemoteFileBrowserMode
    let onSelect: (RemoteFileBrowserSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RemoteFileBrowserModel
    @State private var showingManualPath = false
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var showingCreateError = false
    @State private var renamingEntry: RemoteFileEntry?
    @State private var renameText = ""
    @State private var showingRenameError = false
    @State private var deletingEntry: RemoteFileEntry?
    @State private var showingDeleteError = false

    init(
        alias: String,
        initialPath: String,
        mode: RemoteFileBrowserMode,
        onSelect: @escaping (RemoteFileBrowserSelection) -> Void
    ) {
        self.mode = mode
        self.onSelect = onSelect
        _model = StateObject(wrappedValue: RemoteFileBrowserModel(
            alias: alias,
            initialPath: initialPath.isEmpty ? "." : initialPath
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserContent
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            model.loadInitialPath()
        }
        // "Yeni Klasör" ad girişi alert
        .alert("New Folder", isPresented: $showingCreateFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                model.createDirectory(name: newFolderName)
                newFolderName = ""
            }
            .disabled(!RemoteFileNameValidator.isValid(newFolderName))
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            if let currentPath = model.snapshot?.path {
                Text("A new folder will be added inside \(currentPath).")
            }
        }
        // Oluşturma hatası alert — düzgün dismiss edilebilen binding
        .alert("Folder could not be created", isPresented: $showingCreateError) {
            Button("OK") { model.clearCreateError() }
        } message: {
            Text(model.createError ?? "")
        }
        .onChange(of: model.createError) { _, newValue in
            showingCreateError = newValue != nil
        }
        // "Yeniden Adlandır" ad girişi alert
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renamingEntry != nil },
                set: { isPresented in if !isPresented { renamingEntry = nil } }
            )
        ) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let entry = renamingEntry {
                    model.rename(entry: entry, to: renameText)
                }
                renamingEntry = nil
                renameText = ""
            }
            .disabled(!RemoteFileNameValidator.isValid(renameText))
            Button("Cancel", role: .cancel) {
                renamingEntry = nil
                renameText = ""
            }
        } message: {
            if let entry = renamingEntry {
                Text("Enter a new name for \"\(entry.name)\".")
            }
        }
        .alert("Could not rename", isPresented: $showingRenameError) {
            Button("OK") { model.clearRenameError() }
        } message: {
            Text(model.renameError ?? "")
        }
        .onChange(of: model.renameError) { _, newValue in
            showingRenameError = newValue != nil
        }
        // Silme onayı — dosya adı ve tam uzak yol gösterilir.
        .confirmationDialog(
            "Delete",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { isPresented in if !isPresented { deletingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = deletingEntry {
                    model.delete(entry: entry)
                }
                deletingEntry = nil
            }
            Button("Cancel", role: .cancel) { deletingEntry = nil }
        } message: {
            if let entry = deletingEntry {
                Text(deleteConfirmationMessage(for: entry))
            }
        }
        .alert("Could not delete", isPresented: $showingDeleteError) {
            Button("OK") { model.clearDeleteError() }
        } message: {
            Text(model.deleteError ?? "")
        }
        .onChange(of: model.deleteError) { _, newValue in
            showingDeleteError = newValue != nil
        }
    }

    private func deleteConfirmationMessage(for entry: RemoteFileEntry) -> String {
        if entry.kind == .directory {
            return String(localized: "\"\(entry.name)\" (\(entry.path)) will be permanently deleted. This action cannot be undone. Only an empty folder can be deleted; this app doesn't delete folders recursively.")
        }
        return String(localized: "\"\(entry.name)\" (\(entry.path)) will be permanently deleted. This action cannot be undone.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .directory ? "Select remote folder" : "Select remote file")
                        .font(.title2.weight(.semibold))
                    Text(model.alias)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Home folder", systemImage: "house") {
                    model.loadHome()
                }
                .labelStyle(.iconOnly)
                .help("Go to remote home folder")
                .accessibilityLabel("Go to remote home folder")

                Button("Parent folder", systemImage: "arrow.up") {
                    model.loadParent()
                }
                .labelStyle(.iconOnly)
                .help("Go to parent folder")
                .accessibilityLabel("Go to parent folder")
                .disabled(model.snapshot?.path == "/" || model.snapshot == nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refresh()
                }
                .labelStyle(.iconOnly)
                .help("Refresh remote folder")
                .accessibilityLabel("Refresh remote folder")

                if mode == .directory {
                    Divider()
                        .padding(.horizontal, 2)

                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showingCreateFolder = true
                    }
                    .labelStyle(.iconOnly)
                    .help("Create a new folder at this location")
                    .accessibilityLabel("Create new folder")
                    .disabled(model.snapshot == nil || model.isLoading || model.isCreatingDirectory)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, breadcrumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(breadcrumb.label) {
                            model.load(path: breadcrumb.path)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospaced())
            }

            DisclosureGroup("Enter path manually", isExpanded: $showingManualPath) {
                HStack {
                    TextField("Remote folder path", text: $model.manualPath, prompt: Text("e.g. /var/www"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.loadManualPath() }
                    Button("Go") {
                        model.loadManualPath()
                    }
                    .disabled(model.manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.footnote)
        }
        .padding(20)
    }

    @ViewBuilder
    private var browserContent: some View {
        ZStack {
            if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Remote folder could not be opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { model.refresh() }
                }
            } else if let entries = model.snapshot?.entries, entries.isEmpty, !model.isLoading {
                ContentUnavailableView(
                    "Folder is empty",
                    systemImage: "folder",
                    description: Text("No files to show in this remote folder.")
                )
            } else {
                List {
                    ForEach(model.snapshot?.entries ?? []) { entry in
                        HStack(spacing: 10) {
                            Button {
                                model.open(entry)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: iconName(for: entry))
                                        .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .lineLimit(1)
                                        Text(entry.modificationDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(mode == .directory && entry.kind != .directory)

                            Spacer()
                            if entry.kind == .file, let size = entry.size {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Menu {
                                rowActions(for: entry)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 22)
                            .help("Actions for \(entry.name)")
                            .accessibilityLabel("Actions for \(entry.name)")

                            if entry.kind == .directory {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .listRowBackground(
                            model.selectedFileID == entry.id
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                        .contextMenu {
                            rowActions(for: entry)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: entry))
                    }
                }
                .listStyle(.inset)
                .background(
                    // Finder-style "kısayol": seçili dosya varken Delete tuşu silme onayını açar.
                    // `.onDeleteCommand` was tried here but is focus-dependent through the responder
                    // chain, and this List has no `selection:` binding (rows are plain Buttons) — its
                    // actual focus behavior couldn't be verified without a live SFTP host, so the
                    // always-fires `.keyboardShortcut(.delete)` hack is kept per plan's fallback rule.
                    Button("Delete") {
                        if let entry = model.selectedFile {
                            deletingEntry = entry
                        }
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedFile == nil)
                    .opacity(0)
                )
            }

            if model.isLoading {
                ProgressView("Loading remote folder…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var footer: some View {
        HStack {
            if mode == .directory, let path = model.snapshot?.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let file = model.selectedFile {
                Text(file.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            Button(mode == .directory ? "Select this folder" : "Select file") {
                selectCurrentItem()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSelect)
        }
        .padding(20)
    }

    private var canSelect: Bool {
        switch mode {
        case .directory:
            return model.snapshot != nil && !model.isLoading
        case .file:
            return model.selectedFile.map { $0.kind == .file || $0.kind == .symbolicLink } ?? false
        }
    }

    private func selectCurrentItem() {
        switch mode {
        case .directory:
            guard let snapshot = model.snapshot else { return }
            onSelect(.directory(snapshot))
        case .file:
            guard let file = model.selectedFile else { return }
            onSelect(.file(file))
        }
        dismiss()
    }

    /// Shared "Yeniden Adlandır…" / "Sil…" actions, used both from the right-click
    /// context menu and the trailing ellipsis menu button on each row.
    @ViewBuilder
    private func rowActions(for entry: RemoteFileEntry) -> some View {
        Button("Rename…") {
            renamingEntry = entry
            renameText = entry.name
        }
        Button("Delete…", role: .destructive) {
            deletingEntry = entry
        }
    }

    private func iconName(for entry: RemoteFileEntry) -> String {
        switch entry.kind {
        case .directory:
            return "folder.fill"
        case .file:
            return "doc"
        case .symbolicLink:
            return "link"
        }
    }

    private func accessibilityLabel(for entry: RemoteFileEntry) -> String {
        switch entry.kind {
        case .directory:
            return String(localized: "\(entry.name), folder")
        case .file:
            return String(localized: "\(entry.name), file")
        case .symbolicLink:
            return String(localized: "\(entry.name), symbolic link")
        }
    }
}
