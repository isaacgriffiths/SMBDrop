import BackgroundTasks
import Combine
import Foundation
import UIKit

@MainActor
final class TransferQueueViewModel: ObservableObject {
    private static let continuedTaskIdentifier = "com.isaacgriffiths.smbdrop.transfer"

    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var isDraining = false
    @Published private(set) var message: String?
    @Published private(set) var activeBatchID: UUID?
    @Published private(set) var destinationNames: [UUID: String] = [:]
    @Published private(set) var pendingRemovalIDs: Set<UUID> = []

    private let destinationStore: DestinationStore
    private let worker: SMBTransferWorker
    private let outboxFactory: () throws -> TransferOutbox
    private var resumeRequested = false
    private var isContinuedTaskRegistered = false
    private var isContinuedTaskRunning = false
    private var reportContinuedProgress: ((TransferBatchProgress) -> Void)?

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

    func startUserInitiatedTransfer() async {
        if #available(iOS 26.0, *), submitContinuedProcessingTask() {
            return
        }

        let backgroundAssertion = LegacyTransferBackgroundAssertion()
        backgroundAssertion.begin()
        await resume()
        backgroundAssertion.end()
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
            prunePendingRemovalIDs()
            reportProgressIfNeeded()
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
            prunePendingRemovalIDs()
            reportProgressIfNeeded()

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
                prunePendingRemovalIDs()
                reportProgressIfNeeded()
                if let failed = result.failed {
                    message = failed.errorMessage
                }
                if result.completed.isEmpty,
                   result.failed == nil,
                   transfers.contains(where: { $0.id == nextTransfer.id }) {
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
        guard !pendingRemovalIDs.contains(id) else { return }
        pendingRemovalIDs.insert(id)
        do {
            let outbox = try outboxFactory()
            let result = try await outbox.requestRemoval(id)
            transfers = try await outbox.transfers()
            prunePendingRemovalIDs()
            if result == .cancellationRequested {
                await resume()
            }
        } catch {
            pendingRemovalIDs.remove(id)
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

    private func prunePendingRemovalIDs() {
        let retainedIDs = Set(transfers.filter { $0.status != .completed }.map(\.id))
        pendingRemovalIDs.formIntersection(retainedIDs)
    }

    @available(iOS 26.0, *)
    private func submitContinuedProcessingTask() -> Bool {
        if isContinuedTaskRunning {
            Task { await self.resume() }
            return true
        }

        if !isContinuedTaskRegistered {
            isContinuedTaskRegistered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.continuedTaskIdentifier,
                using: nil
            ) { [weak self] submittedTask in
                guard let task = submittedTask as? BGContinuedProcessingTask else {
                    submittedTask.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    await self.runContinuedProcessingTask(task)
                }
            }
        }
        guard isContinuedTaskRegistered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedTaskIdentifier,
            title: "Uploading to SMB",
            subtitle: "Preparing transfer…"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func runContinuedProcessingTask(_ task: BGContinuedProcessingTask) async {
        isContinuedTaskRunning = true
        reportContinuedProgress = { progress in
            let totalUnits = max(1, progress.totalBytes)
            task.progress.totalUnitCount = totalUnits
            task.progress.completedUnitCount = min(
                totalUnits,
                max(0, progress.bytesTransferred)
            )
            let percent = Int(progress.fractionCompleted * 100)
            task.updateTitle(
                "Uploading to SMB",
                subtitle: "\(progress.countText) · \(percent)%"
            )
        }
        reportProgressIfNeeded()

        let operation = Task { @MainActor [weak self] in
            await self?.resume()
        }
        task.expirationHandler = {
            operation.cancel()
        }
        await operation.value

        let trackedTransfers = activeTransfers
        let hasUnfinished = trackedTransfers.contains {
            $0.status == .queued || $0.status == .uploading
        }
        let hasFailure = trackedTransfers.contains { $0.status == .failed }
        task.setTaskCompleted(
            success: !operation.isCancelled && !hasUnfinished && !hasFailure
        )
        reportContinuedProgress = nil
        isContinuedTaskRunning = false
    }

    private func reportProgressIfNeeded() {
        guard let activeProgress else { return }
        reportContinuedProgress?(activeProgress)
    }

    private func replace(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
            transfers.sort { $0.createdAt < $1.createdAt }
        }
        reportProgressIfNeeded()
    }
}

@MainActor
private final class LegacyTransferBackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Finish SMB transfer"
        ) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
