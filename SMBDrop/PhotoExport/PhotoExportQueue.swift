import Foundation

/// One Photos send or backup run. Photos stay as library identifiers until a
/// chunk is staged, so selecting a whole library costs a list of IDs, not a
/// second copy of every original on disk.
struct PhotoExportBatch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let destinationID: UUID
    let isAutomaticBackup: Bool
    let createdAt: Date
    /// Every photo in the batch, in send order. Only ever appended to, or
    /// cut back to `consumedCount` when the rest is cancelled.
    var assetIDs: [String]
    /// How many of `assetIDs` have been staged, skipped, or failed to copy.
    var consumedCount = 0
    var counts = ChunkedBatchCounts()
    /// Set when a chunk made no progress (the share is unreachable, or the
    /// phone is out of space), so a backup stops instead of copying out and
    /// failing the rest of the library. Cleared by the next explicit run.
    var isPaused = false
    /// The outbox items staged by the most recent chunk, used to tell whether
    /// that chunk got anything through.
    var lastChunkTransferIDs: [UUID] = []

    init(
        id: UUID = UUID(),
        destinationID: UUID,
        isAutomaticBackup: Bool,
        createdAt: Date = Date(),
        assetIDs: [String]
    ) {
        self.id = id
        self.destinationID = destinationID
        self.isAutomaticBackup = isAutomaticBackup
        self.createdAt = createdAt
        self.assetIDs = assetIDs
        counts.unstaged = assetIDs.count
    }

    var pendingCount: Int { max(0, assetIDs.count - consumedCount) }
    var nextAssetID: String? { pendingCount > 0 ? assetIDs[consumedCount] : nil }
    var pendingAssetIDs: ArraySlice<String> { assetIDs[min(consumedCount, assetIDs.count)...] }
    var isFinishedStaging: Bool { pendingCount == 0 }

    /// Marks the next photo as handled, whatever happened to it.
    mutating func consumeNext() {
        consumedCount = min(consumedCount + 1, assetIDs.count)
    }
}

/// The durable list of Photos exports. Lives in the main app's own container:
/// only the main app reads the photo library, and the outbox it feeds is the
/// part shared with the Share Extension.
struct PhotoExportQueue: Equatable, Sendable {
    private(set) var batches: [PhotoExportBatch]

    /// Finished batches stay so their progress reads "N of N" until the next
    /// export starts; only this many are kept.
    static let retainedFinishedBatches = 3

    init(batches: [PhotoExportBatch] = []) {
        self.batches = batches
    }

    var hasStageableWork: Bool {
        nextBatchToStage != nil
    }

    /// A send the user just made goes ahead of a long-running backup.
    var nextBatchToStage: PhotoExportBatch? {
        let stageable = batches.filter { !$0.isFinishedStaging && !$0.isPaused }
        return stageable.first(where: { !$0.isAutomaticBackup }) ?? stageable.first
    }

    var pendingBackupAssetIDs: Set<String> {
        Set(batches.filter(\.isAutomaticBackup).flatMap(\.pendingAssetIDs))
    }

    var counts: [UUID: ChunkedBatchCounts] {
        Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0.counts) })
    }

    subscript(id: UUID) -> PhotoExportBatch? {
        batches.first(where: { $0.id == id })
    }

    mutating func add(_ batch: PhotoExportBatch) {
        let finishedIDs = batches.filter(\.isFinishedStaging).map(\.id)
        let dropped = Set(finishedIDs.dropLast(Self.retainedFinishedBatches - 1))
        batches.removeAll { dropped.contains($0.id) }
        batches.append(batch)
    }

    /// New photos found by a backup run join the backup already in progress
    /// for that share, so one backup never shows as several batches.
    @discardableResult
    mutating func appendBackupAssets(
        _ assetIDs: [String],
        destinationID: UUID,
        now: Date = Date()
    ) -> UUID? {
        let alreadyPending = pendingBackupAssetIDs
        let newIDs = assetIDs.filter { !alreadyPending.contains($0) }
        guard !newIDs.isEmpty else { return nil }
        if let index = batches.lastIndex(where: {
            $0.isAutomaticBackup && $0.destinationID == destinationID && !$0.isFinishedStaging
        }) {
            batches[index].assetIDs.append(contentsOf: newIDs)
            batches[index].counts.unstaged = batches[index].pendingCount
            return batches[index].id
        }
        let batch = PhotoExportBatch(
            destinationID: destinationID,
            isAutomaticBackup: true,
            createdAt: now,
            assetIDs: newIDs
        )
        add(batch)
        return batch.id
    }

    mutating func update(_ id: UUID, _ change: (inout PhotoExportBatch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        change(&batches[index])
        batches[index].counts.unstaged = batches[index].pendingCount
    }

    /// Drops photos that were never staged. Already staged items stay in the
    /// outbox, where they can be sent or removed like any other transfer.
    mutating func cancelUnstaged(where shouldCancel: (PhotoExportBatch) -> Bool) {
        for index in batches.indices where shouldCancel(batches[index]) {
            batches[index].assetIDs.removeSubrange(batches[index].consumedCount...)
            batches[index].counts.unstaged = 0
            batches[index].isPaused = false
        }
    }

    mutating func unpauseAll() {
        for index in batches.indices {
            batches[index].isPaused = false
        }
    }

    /// A chunk that got nothing through because of the share or network
    /// (not because of one file's own name clash) pauses its batch.
    static func shouldPause(afterChunk transfers: [Transfer]) -> Bool {
        !transfers.isEmpty
            && !transfers.contains { $0.status == .completed }
            && transfers.contains { $0.status == .failed && !$0.hasItemSpecificFailure }
    }
}

/// Saves the queue after every staged photo, so it must stay cheap: batch
/// state goes in one small file, and each batch's ID list (which can hold a
/// whole library) is rewritten only when the list itself changes.
final class PhotoExportQueueStore {
    let directoryURL: URL
    private var savedIDCounts: [UUID: Int] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    static func standard(fileManager: FileManager = .default) -> PhotoExportQueueStore {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PhotoExportQueueStore(
            directoryURL: support.appendingPathComponent("PhotoExports", isDirectory: true)
        )
    }

    private var stateURL: URL {
        directoryURL.appendingPathComponent("batches.json", isDirectory: false)
    }

    private func idsURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).ids.json", isDirectory: false)
    }

    func load() -> PhotoExportQueue {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode([PhotoExportBatch].self, from: data) else {
            return PhotoExportQueue()
        }
        let batches = stored.compactMap { batch -> PhotoExportBatch? in
            guard let idsData = try? Data(contentsOf: idsURL(for: batch.id)),
                  let assetIDs = try? JSONDecoder().decode([String].self, from: idsData) else {
                return nil
            }
            var loaded = batch
            loaded.assetIDs = assetIDs
            loaded.consumedCount = min(batch.consumedCount, assetIDs.count)
            loaded.counts.unstaged = loaded.pendingCount
            savedIDCounts[batch.id] = assetIDs.count
            return loaded
        }
        return PhotoExportQueue(batches: batches)
    }

    func save(_ queue: PhotoExportQueue) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for batch in queue.batches where savedIDCounts[batch.id] != batch.assetIDs.count {
            try JSONEncoder().encode(batch.assetIDs).write(to: idsURL(for: batch.id), options: .atomic)
            savedIDCounts[batch.id] = batch.assetIDs.count
        }
        let state = queue.batches.map { batch -> PhotoExportBatch in
            var stripped = batch
            stripped.assetIDs = []
            return stripped
        }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)

        let liveIDs = Set(queue.batches.map(\.id))
        for id in savedIDCounts.keys where !liveIDs.contains(id) {
            try? FileManager.default.removeItem(at: idsURL(for: id))
            savedIDCounts[id] = nil
        }
    }
}
