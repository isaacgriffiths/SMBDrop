import Combine
import Foundation
import Photos

/// Feeds Photos sends and automatic backups into the durable outbox a chunk
/// at a time. The transfer queue asks for the next chunk only once the
/// outbox has nothing queued, so disk use stays at roughly one chunk however
/// many photos are selected.
@MainActor
final class PhotoExportCoordinator: ObservableObject {
    static let shared = PhotoExportCoordinator(transferQueue: .shared)

    static let chunkAssetLimit = 20
    static let chunkByteLimit: Int64 = 1_000_000_000
    static let stagingFailureLimit = 3

    @Published private(set) var queue: PhotoExportQueue

    /// Called for each photo a backup hands to the outbox. From then on the
    /// outbox owns it, so the backup can count it as done.
    var onBackupAssetStaged: ((_ destinationID: UUID, _ assetID: String) -> Void)?

    let transferQueue: TransferQueueViewModel
    private let store: PhotoExportQueueStore
    private let exporter = PhotoAssetExporter()

    init(
        transferQueue: TransferQueueViewModel,
        store: PhotoExportQueueStore = .standard()
    ) {
        self.transferQueue = transferQueue
        self.store = store
        queue = store.load()
        transferQueue.stageMoreWork = { [weak self] in
            await self?.stageNextChunk() ?? false
        }
        publishCounts()
    }

    var backupBatchIDs: Set<UUID> {
        Set(queue.batches.filter(\.isAutomaticBackup).map(\.id))
    }

    var pendingBackupCount: Int {
        queue.batches.filter(\.isAutomaticBackup).reduce(0) { $0 + $1.pendingCount }
    }

    var isBackupPaused: Bool {
        queue.batches.contains { $0.isAutomaticBackup && $0.isPaused }
    }

    /// A user-picked selection, however large. Returns once the system has
    /// accepted the transfer; the photos themselves are copied as it runs.
    func send(assetIDs: [String], to destinationID: UUID) async {
        guard !assetIDs.isEmpty else { return }
        let batch = PhotoExportBatch(
            destinationID: destinationID,
            isAutomaticBackup: false,
            assetIDs: assetIDs
        )
        queue.add(batch)
        persist()
        transferQueue.track(batchID: batch.id)
        await transferQueue.startUserInitiatedTransfer()
    }

    /// Adds photos to the backup for a share. The caller starts the drain.
    func enqueueBackup(assetIDs: [String], destinationID: UUID) {
        guard let batchID = queue.appendBackupAssets(assetIDs, destinationID: destinationID) else {
            return
        }
        persist()
        if transferQueue.activeProgress == nil || transferQueue.activeBatchID == batchID {
            transferQueue.track(batchID: batchID)
        }
    }

    /// Stops backups that have not been copied out yet, for every share or
    /// for every share except one.
    func cancelBackups(except destinationID: UUID? = nil) {
        queue.cancelUnstaged {
            $0.isAutomaticBackup && $0.destinationID != destinationID
        }
        persist()
    }

    /// An explicit run (opening the app, Back Up Now, a background task)
    /// gives paused batches another go and retries failures that a better
    /// connection could fix.
    func prepareForRun() async {
        queue.unpauseAll()
        persist()
        let retryable = backupBatchIDs
        await transferQueue.requeueFailed(in: retryable)
    }

    /// Installed as the transfer queue's refill hook.
    func stageNextChunk() async -> Bool {
        guard let batch = queue.nextBatchToStage else { return false }

        let lastChunk = transferQueue.transfers.filter {
            batch.lastChunkTransferIDs.contains($0.id)
        }
        if PhotoExportQueue.shouldPause(afterChunk: lastChunk) {
            queue.update(batch.id) { $0.isPaused = true }
            persist()
            transferQueue.report(pausedMessage(for: batch, failure: lastChunk.last?.errorMessage))
            // Another batch may still be able to go.
            return queue.hasStageableWork
        }

        do {
            let archived = try await transferQueue.archiveCompleted(in: batch.id)
            queue.update(batch.id) {
                $0.counts.archivedCompleted += archived.count
                $0.counts.archivedBytes += archived.reduce(0) { $0 + $1.byteCount }
            }
        } catch {
            transferQueue.report(error.localizedDescription)
            return false
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDrop-Photos-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            transferQueue.report(error.localizedDescription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var stagedTransferIDs: [UUID] = []
        var stagedBytes: Int64 = 0
        var consecutiveFailures = 0
        var madeProgress = false
        while stagedTransferIDs.count < Self.chunkAssetLimit,
              stagedBytes < Self.chunkByteLimit,
              !Task.isCancelled,
              let assetID = queue[batch.id]?.nextAssetID {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetID],
                options: nil
            ).firstObject else {
                // Deleted from the library since it was picked.
                queue.update(batch.id) { $0.consumeNext() }
                madeProgress = true
                continue
            }

            do {
                let resources = try await exporter.stage(asset, in: directoryURL)
                var transfers: [Transfer] = []
                do {
                    for resource in resources {
                        transfers.append(
                            try await transferQueue.enqueueFile(
                                at: resource.fileURL,
                                filename: resource.filename,
                                destinationID: batch.destinationID,
                                batchID: batch.id,
                                moveSource: true,
                                acceptsIdenticalExistingFile: batch.isAutomaticBackup
                            )
                        )
                    }
                } catch TransferOutboxError.destinationRemoved {
                    queue.cancelUnstaged { $0.id == batch.id }
                    persist()
                    transferQueue.report(TransferOutboxError.destinationRemoved.localizedDescription)
                    return queue.hasStageableWork
                }
                stagedTransferIDs += transfers.map(\.id)
                stagedBytes += transfers.reduce(0) { $0 + $1.byteCount }
                queue.update(batch.id) { $0.consumeNext() }
                if batch.isAutomaticBackup {
                    onBackupAssetStaged?(batch.destinationID, assetID)
                }
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.stagingFailureLimit {
                    // Likely out of space or offline for iCloud originals:
                    // keep the rest for a later run rather than failing them all.
                    queue.update(batch.id) { $0.isPaused = true }
                    persist()
                    transferQueue.report(pausedMessage(for: batch, failure: error.localizedDescription))
                    break
                }
                queue.update(batch.id) {
                    $0.consumeNext()
                    $0.counts.failedToStage += 1
                }
                transferQueue.report("Could not copy a photo out of your library: \(error.localizedDescription)")
            }
            madeProgress = true
            // Persist per photo so a relaunch never stages the same one twice.
            queue.update(batch.id) { $0.lastChunkTransferIDs = stagedTransferIDs }
            persist()
        }
        persist()
        return madeProgress && !Task.isCancelled
    }

    private func pausedMessage(for batch: PhotoExportBatch, failure: String?) -> String {
        let kind = batch.isAutomaticBackup ? "Backup" : "Sending"
        let reason = failure.map { " \($0)" } ?? ""
        return "\(kind) paused.\(reason)"
    }

    private func persist() {
        try? store.save(queue)
        publishCounts()
    }

    private func publishCounts() {
        transferQueue.setChunkedCounts(queue.counts)
    }
}
