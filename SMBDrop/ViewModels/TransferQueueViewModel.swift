import Combine
import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var isDraining = false
    @Published private(set) var message: String?
    @Published private(set) var activeBatchID: UUID?
    @Published private(set) var destinationNames: [UUID: String] = [:]

    private let destinationStore: DestinationStore
    private let worker: SMBTransferWorker
    private let outboxFactory: () throws -> TransferOutbox
    private var resumeRequested = false

    init(
        destinationStore: DestinationStore = DestinationStore(),
        worker: SMBTransferWorker = SMBTransferWorker(),
        outboxFactory: @escaping () throws -> TransferOutbox = { try TransferOutbox.shared() }
    ) {
        self.destinationStore = destinationStore
        self.worker = worker
        self.outboxFactory = outboxFactory
    }

    var activeTransfers: [Transfer] {
        if let uploading = transfers.first(where: { $0.status == .uploading }) {
            if let batchID = uploading.batchID {
                return transfers.filter { $0.batchID == batchID }
            }
            return transfers.filter {
                $0.batchID == nil
                    && ($0.status == .queued || $0.status == .uploading || $0.status == .failed)
            }
        }

        if let activeBatchID {
            let batch = transfers.filter { $0.batchID == activeBatchID }
            if !batch.isEmpty { return batch }
        }

        let unfinished = transfers.filter {
            $0.status == .queued || $0.status == .uploading || $0.status == .failed
        }
        if let batchID = unfinished.reversed().compactMap(\.batchID).first {
            return transfers.filter { $0.batchID == batchID }
        }
        return unfinished
    }

    var activeProgress: TransferBatchProgress? {
        let activeTransfers = activeTransfers
        return activeTransfers.isEmpty ? nil : TransferBatchProgress(transfers: activeTransfers)
    }

    func track(batchID: UUID) {
        activeBatchID = batchID
        message = nil
    }

    @discardableResult
    func enqueueFile(
        at sourceURL: URL,
        filename: String,
        destinationID: UUID,
        batchID: UUID,
        moveSource: Bool = false
    ) async throws -> Transfer {
        let outbox = try outboxFactory()
        let transfer = try await outbox.enqueueFile(
            at: sourceURL,
            filename: filename,
            destinationID: destinationID,
            batchID: batchID,
            moveSource: moveSource
        )
        replace(transfer)
        return transfer
    }

    func refresh() async {
        do {
            let outbox = try outboxFactory()
            transfers = try await outbox.transfers()
            updateDestinationNames()
        } catch {
            message = error.localizedDescription
        }
    }

    func resume() async {
        guard !isDraining else {
            resumeRequested = true
            return
        }
        do {
            let outbox = try outboxFactory()
            let destinations = try destinationStore.loadAll()
            try await outbox.reconcileRetiredDestinations(
                with: Set(destinations.map(\.id))
            )
            destinationNames = Dictionary(
                uniqueKeysWithValues: destinations.map { ($0.id, $0.summary.displayName) }
            )

            // The old app had exactly one destination and left queue items
            // unassigned. Bind those items once before any destination worker runs.
            if let legacyDestination = destinations.first {
                try await outbox.assignUnassignedTransfers(to: legacyDestination.id)
            }
            transfers = try await outbox.transfers()

            let unfinished = transfers.filter {
                $0.status == .queued || $0.status == .uploading
            }
            guard !unfinished.isEmpty else { return }
            guard !destinations.isEmpty else {
                message = "Add an SMB share in Settings to upload the queued items."
                return
            }

            let knownIDs = Set(destinations.map(\.id))
            if unfinished.contains(where: { transfer in
                guard let destinationID = transfer.destinationID else { return true }
                return !knownIDs.contains(destinationID)
            }) {
                message = "A queued item belongs to an SMB share that is no longer saved."
            } else {
                message = nil
            }

            isDraining = true
            defer {
                isDraining = false
                if resumeRequested {
                    resumeRequested = false
                    Task { await self.resume() }
                }
            }

            let destinationsByID = Dictionary(
                uniqueKeysWithValues: destinations.map { ($0.id, $0) }
            )
            while let nextTransfer = transfers.first(where: {
                $0.status == .queued || $0.status == .uploading
            }) {
                guard let destinationID = nextTransfer.destinationID,
                      let savedDestination = destinationsByID[destinationID] else {
                    message = "A queued item belongs to an SMB share that is no longer saved."
                    break
                }
                let result = await worker.drain(
                    outbox: outbox,
                    destination: savedDestination.destination,
                    password: savedDestination.password,
                    destinationID: savedDestination.id,
                    transferIDs: Set([nextTransfer.id])
                ) { [weak self] updatedTransfer in
                    Task { @MainActor in
                        self?.replace(updatedTransfer)
                    }
                }
                transfers = try await outbox.transfers()
                if let failed = result.failed {
                    message = failed.errorMessage
                }
                if result.completed.isEmpty && result.failed == nil {
                    // Another process owns the active claim. It will either
                    // finish the item or leave it for a later foreground resume.
                    break
                }
            }
        } catch {
            message = error.localizedDescription
            isDraining = false
        }
    }

    func retry(_ id: UUID) async {
        do {
            let outbox = try outboxFactory()
            let retried = try await outbox.retry(id)
            activeBatchID = retried.batchID
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

    func destinationName(for transfer: Transfer) -> String? {
        transfer.destinationID.flatMap { destinationNames[$0] }
    }

    func dismissProgress() {
        activeBatchID = nil
    }

    private func updateDestinationNames() {
        guard let destinations = try? destinationStore.loadAll() else { return }
        destinationNames = Dictionary(
            uniqueKeysWithValues: destinations.map { ($0.id, $0.summary.displayName) }
        )
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
