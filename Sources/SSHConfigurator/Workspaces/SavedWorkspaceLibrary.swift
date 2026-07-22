import Foundation
import Combine

@MainActor
final class SavedWorkspaceLibrary: ObservableObject {
    @Published private(set) var workspaces: [SavedWorkspace] = []
    @Published var errorMessage: String?

    private let store: any SavedWorkspacePersisting

    init(store: any SavedWorkspacePersisting = SavedWorkspaceStore()) {
        self.store = store
    }

    func load() {
        do {
            workspaces = try store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Insert-or-replace by `id`; `updatedAt` is always bumped to now,
    /// whether this is a fresh insert or a replace of an existing snapshot.
    @discardableResult
    func save(_ workspace: SavedWorkspace) -> Bool {
        var updated = workspace
        updated.updatedAt = .now
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = updated
        } else {
            workspaces.append(updated)
        }
        return persist()
    }

    @discardableResult
    func delete(id: SavedWorkspace.ID) -> Bool {
        workspaces.removeAll { $0.id == id }
        return persist()
    }

    func dismissError() {
        errorMessage = nil
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(workspaces)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
