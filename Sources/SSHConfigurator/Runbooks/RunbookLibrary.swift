import Foundation
import Combine

@MainActor
final class RunbookLibrary: ObservableObject {
    @Published private(set) var runbooks: [Runbook] = []
    @Published var errorMessage: String?

    private let store: any RunbookPersisting

    init(store: any RunbookPersisting = RunbookStore()) {
        self.store = store
    }

    func load() {
        do {
            runbooks = try store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addOrUpdate(_ runbook: Runbook) {
        if let index = runbooks.firstIndex(where: { $0.id == runbook.id }) {
            runbooks[index] = runbook
        } else {
            runbooks.append(runbook)
        }
        persist()
    }

    func remove(_ runbook: Runbook) {
        runbooks.removeAll { $0.id == runbook.id }
        persist()
    }

    func remove(at offsets: IndexSet) {
        runbooks.remove(atOffsets: offsets)
        persist()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func persist() {
        do {
            try store.save(runbooks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
