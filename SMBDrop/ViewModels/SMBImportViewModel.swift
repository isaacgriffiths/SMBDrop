import Combine
import Foundation

@MainActor
final class SMBImportViewModel: ObservableObject {
    @Published private(set) var destinationID: UUID?
    @Published private(set) var currentPath = ""
    @Published private(set) var items: [SMBRemoteItem] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var importProgress: SMBImportProgress?
    @Published private(set) var importedURLs: [URL] = []
    @Published var errorMessage: String?

    private let service: any SMBImportServing

    init(service: any SMBImportServing = SMBImportService()) {
        self.service = service
    }

    var selectedCount: Int { selectedIDs.count }
    var isImporting: Bool { importProgress != nil }
    var canBrowseToParent: Bool { !currentPath.isEmpty && !isLoading && !isImporting }

    var selectedItems: [SMBRemoteItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func openDestination(_ id: UUID) async {
        destinationID = id
        currentPath = ""
        selectedIDs = []
        importedURLs = []
        await loadCurrentDirectory()
    }

    func closeDestination() {
        guard !isImporting else { return }
        destinationID = nil
        currentPath = ""
        items = []
        selectedIDs = []
        importedURLs = []
        errorMessage = nil
    }

    func openFolder(_ item: SMBRemoteItem) async {
        guard item.isDirectory, !isImporting else { return }
        currentPath = item.relativePath
        selectedIDs = []
        importedURLs = []
        await loadCurrentDirectory()
    }

    func browseToParent() async {
        guard canBrowseToParent else { return }
        var components = currentPath.split(separator: "/").map(String.init)
        _ = components.popLast()
        currentPath = components.joined(separator: "/")
        selectedIDs = []
        importedURLs = []
        await loadCurrentDirectory()
    }

    func refresh() async {
        guard destinationID != nil, !isImporting else { return }
        await loadCurrentDirectory()
    }

    func toggle(_ item: SMBRemoteItem) {
        guard !item.isDirectory, !isImporting else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        importedURLs = []
    }

    func clearSelection() {
        guard !isImporting else { return }
        selectedIDs = []
    }

    func importSelection() async {
        guard let destinationID, !selectedItems.isEmpty, !isImporting else { return }
        let selection = selectedItems
        importedURLs = []
        errorMessage = nil
        importProgress = SMBImportProgress(
            filename: selection[0].name,
            completedItemCount: 0,
            totalItemCount: selection.count,
            bytesTransferred: 0,
            totalBytes: selection[0].byteCount
        )
        let (progressStream, progressContinuation) = AsyncStream<SMBImportProgress>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.importProgress = progress
            }
        }

        do {
            let urls = try await service.importItems(
                selection,
                from: destinationID
            ) { progress in
                progressContinuation.yield(progress)
            }
            progressContinuation.finish()
            await progressTask.value
            importedURLs = urls
            selectedIDs = []
            importProgress = nil
        } catch {
            progressContinuation.finish()
            await progressTask.value
            importProgress = nil
            if let partialFailure = error as? SMBImportPartialFailure {
                importedURLs = partialFailure.importedURLs
                selectedIDs.subtract(Set(partialFailure.importedItems.map(\.id)))
            }
            errorMessage = error.localizedDescription
        }
    }

    private func loadCurrentDirectory() async {
        guard let destinationID else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await service.contents(of: destinationID, at: currentPath)
            selectedIDs.formIntersection(Set(items.map(\.id)))
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }
}
