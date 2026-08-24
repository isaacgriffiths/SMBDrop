import Combine
import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var isDraining = false
    @Published private(set) var message: String?

    private let destinationStore: DestinationStore
    private let worker: SMBTransferWorker
    private let outboxFactory: () throws -> TransferOutbox

    init(
        destinationStore: DestinationStore = DestinationStore(),
        worker: SMBTransferWorker = SMBTransferWorker(),
        outboxFactory: @escaping () throws -> TransferOutbox = { try TransferOutbox.shared() }
    ) {
        self.destinationStore = destinationStore
        self.worker = worker
        self.outboxFactory = outboxFactory
    }

    func resume() async {
        guard !isDraining else { return }
        do {
            let outbox = try outboxFactory()
            transfers = try await outbox.transfers()
            guard transfers.contains(where: { $0.status == .queued || $0.status == .uploading }) else {
                return
            }
            guard let savedDestination = try destinationStore.load() else {
                message = "Save an SMB destination to upload the queued items."
                return
            }

            isDraining = true
            message = nil
            let result = await worker.drain(
                outbox: outbox,
                destination: savedDestination.destination,
                password: savedDestination.password
            ) { [weak self] updatedTransfer in
                Task { @MainActor in
                    self?.replace(updatedTransfer)
                }
            }
            transfers = try await outbox.transfers()
            if let failed = result.failed {
                message = failed.errorMessage
            }
            isDraining = false
        } catch {
            message = error.localizedDescription
            isDraining = false
        }
    }

    func retry(_ id: UUID) async {
        do {
            let outbox = try outboxFactory()
            let retried = try await outbox.retry(id)
            replace(retried)
            await resume()
        } catch {
            message = error.localizedDescription
        }
    }

    func remove(_ id: UUID) async {
        do {
            let outbox = try outboxFactory()
            try await outbox.remove(id)
            transfers = try await outbox.transfers()
        } catch {
            message = error.localizedDescription
        }
    }

    private func replace(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
            transfers.sort { $0.createdAt < $1.createdAt }
        }
    }
}
