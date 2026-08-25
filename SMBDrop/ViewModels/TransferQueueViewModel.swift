import BackgroundTasks
import Combine
import Foundation
import UIKit

@MainActor
final class TransferQueueViewModel: ObservableObject {
    private static let continuedTaskIdentifierPrefix = "com.isaacgriffiths.smbdrop.transfer"

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
    private var activeDrain: TransferDrainLifetime?
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
        if isContinuedTaskRunning {
            await resume()
            return
        }
        if #available(iOS 26.0, *), await submitContinuedProcessingTask() {
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
        if SampleContent.isEnabled {
            transfers = SampleContent.transfers
            destinationNames = SampleContent.destinationNames
            return
        }
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
        if let activeDrain {
            resumeRequested = true
            await waitForDrain(activeDrain)
            return
        }

        let lifetime = TransferDrainLifetime()
        activeDrain = lifetime
        isDraining = true
        lifetime.task = Task { @MainActor [self, lifetime] in
            repeat {
                resumeRequested = false
                await performDrain()
            } while resumeRequested && !Task.isCancelled
            finishDrain(lifetime)
        }
        await waitForDrain(lifetime)
    }

    private func performDrain() async {
        // Sample Content pauses real queue work so screenshots show the
        // sample history instead of the user's actual transfers.
        if SampleContent.isEnabled {
            transfers = SampleContent.transfers
            destinationNames = SampleContent.destinationNames
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
        }
    }

    private func waitForDrain(_ lifetime: TransferDrainLifetime) async {
        await withCheckedContinuation { continuation in
            guard activeDrain?.id == lifetime.id else {
                continuation.resume()
                return
            }
            lifetime.waiters.append(continuation)
        }
    }

    private func finishDrain(_ lifetime: TransferDrainLifetime) {
        guard activeDrain?.id == lifetime.id else { return }
        activeDrain = nil
        isDraining = false
        lifetime.task = nil
        let waiters = lifetime.waiters
        lifetime.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cancelActiveDrain() {
        activeDrain?.task?.cancel()
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
            } else if result == .tooLate {
                pendingRemovalIDs.remove(id)
                message = "That item was already being published. Remove it from history after it finishes."
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
    private func submitContinuedProcessingTask() async -> Bool {
        let identifier = "\(Self.continuedTaskIdentifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: DispatchQueue.main
        ) { [weak self] submittedTask in
            MainActor.assumeIsolated {
                guard let task = submittedTask as? BGContinuedProcessingTask else {
                    submittedTask.setTaskCompleted(success: false)
                    return
                }
                let context = ContinuedTransferContext(task: task)
                guard let self else {
                    context.task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor [weak self, context] in
                    guard let self else {
                        context.task.setTaskCompleted(success: false)
                        return
                    }
                    await self.runContinuedProcessingTask(context)
                }
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Uploading to SMB",
            subtitle: "Preparing transfer…"
        )
        request.strategy = .queue
        // Xcode 26.3 does not expose the replacement completion-handler API
        // to Swift yet, so keep its synchronous compatibility API off-main.
        let submission = ContinuedTaskRequestBox(request: request)
        let submissionError: (any Error)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try BGTaskScheduler.shared.submit(submission.request)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
        return submissionError == nil
    }

    @available(iOS 26.0, *)
    private func runContinuedProcessingTask(_ context: ContinuedTransferContext) async {
        let task = context.task
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

        task.expirationHandler = { [weak self, context] in
            Task { @MainActor [weak self, context] in
                context.wasExpired = true
                self?.cancelActiveDrain()
            }
        }
        await resume()

        let trackedTransfers = activeTransfers
        let hasUnfinished = trackedTransfers.contains {
            $0.status == .queued || $0.status == .uploading
        }
        let hasFailure = trackedTransfers.contains { $0.status == .failed }
        task.setTaskCompleted(
            success: !context.wasExpired && !hasUnfinished && !hasFailure
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
private final class TransferDrainLifetime {
    let id = UUID()
    var task: Task<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
}

@available(iOS 26.0, *)
@MainActor
private final class ContinuedTransferContext {
    let task: BGContinuedProcessingTask
    var wasExpired = false

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }
}

@available(iOS 26.0, *)
private final class ContinuedTaskRequestBox: @unchecked Sendable {
    let request: BGContinuedProcessingTaskRequest

    init(request: BGContinuedProcessingTaskRequest) {
        self.request = request
    }
}

@MainActor
private final class LegacyTransferBackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Finish SMB transfer"
        ) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
