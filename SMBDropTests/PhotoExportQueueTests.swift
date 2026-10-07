import XCTest
@testable import SMBDrop

final class PhotoExportQueueTests: XCTestCase {
    func testAUserSendIsStagedAheadOfABackupAlreadyInProgress() {
        let share = UUID()
        var queue = PhotoExportQueue()
        let backupID = queue.appendBackupAssets(["a", "b"], destinationID: share)
        let send = PhotoExportBatch(destinationID: share, isAutomaticBackup: false, assetIDs: ["x"])
        queue.add(send)

        XCTAssertEqual(queue.nextBatchToStage?.id, send.id)

        queue.update(send.id) { $0.consumeNext() }
        XCTAssertEqual(queue.nextBatchToStage?.id, backupID)
    }

    func testNewBackupPhotosJoinTheRunningBackupWithoutDuplicates() throws {
        let share = UUID()
        var queue = PhotoExportQueue()
        let first = try XCTUnwrap(queue.appendBackupAssets(["a", "b"], destinationID: share))
        let second = queue.appendBackupAssets(["b", "c"], destinationID: share)

        XCTAssertEqual(second, first)
        XCTAssertEqual(queue[first]?.assetIDs, ["a", "b", "c"])
        XCTAssertEqual(queue[first]?.counts.unstaged, 3)
        XCTAssertNil(queue.appendBackupAssets(["a", "c"], destinationID: share))
    }

    func testABackupThatFinishedStagingStartsAFreshBatch() throws {
        let share = UUID()
        var queue = PhotoExportQueue()
        let first = try XCTUnwrap(queue.appendBackupAssets(["a"], destinationID: share))
        queue.update(first) { $0.consumeNext() }

        let second = try XCTUnwrap(queue.appendBackupAssets(["b"], destinationID: share))

        XCTAssertNotEqual(second, first)
        XCTAssertEqual(queue[first]?.counts.unstaged, 0)
    }

    func testPausedBatchesAreSkippedUntilTheNextRun() throws {
        var queue = PhotoExportQueue()
        let backup = try XCTUnwrap(queue.appendBackupAssets(["a"], destinationID: UUID()))
        queue.update(backup) { $0.isPaused = true }

        XCTAssertFalse(queue.hasStageableWork)

        queue.unpauseAll()
        XCTAssertEqual(queue.nextBatchToStage?.id, backup)
    }

    func testCancellingKeepsWhatWasAlreadyStaged() throws {
        let share = UUID()
        var queue = PhotoExportQueue()
        let backup = try XCTUnwrap(queue.appendBackupAssets(["a", "b", "c"], destinationID: share))
        queue.update(backup) { $0.consumeNext() }

        queue.cancelUnstaged { $0.isAutomaticBackup }

        XCTAssertEqual(queue[backup]?.assetIDs, ["a"])
        XCTAssertEqual(queue[backup]?.counts.unstaged, 0)
        XCTAssertFalse(queue.hasStageableWork)
    }

    func testOnlyTheMostRecentFinishedBatchesAreKept() {
        var queue = PhotoExportQueue()
        var ids: [UUID] = []
        for _ in 0..<5 {
            let batch = PhotoExportBatch(destinationID: UUID(), isAutomaticBackup: false, assetIDs: [])
            queue.add(batch)
            ids.append(batch.id)
        }

        XCTAssertEqual(
            queue.batches.map(\.id),
            Array(ids.suffix(PhotoExportQueue.retainedFinishedBatches))
        )
    }

    func testAChunkThatCouldNotReachTheSharePausesTheBatch() {
        let unreachable = transfer(status: .failed, error: SMBConnectionError.serverUnavailable.errorDescription)
        let clash = transfer(
            status: .failed,
            error: TransferUploadError.fileAlreadyExists("IMG_0001.HEIC").errorDescription
        )
        let sent = transfer(status: .completed)

        XCTAssertTrue(PhotoExportQueue.shouldPause(afterChunk: [unreachable, unreachable]))
        XCTAssertFalse(PhotoExportQueue.shouldPause(afterChunk: [unreachable, sent]))
        XCTAssertFalse(PhotoExportQueue.shouldPause(afterChunk: [clash]))
        XCTAssertFalse(PhotoExportQueue.shouldPause(afterChunk: []))
    }

    func testStoreRoundTripsBatchesAndRemovesFinishedOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExportQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoExportQueueStore(directoryURL: directory)
        var queue = PhotoExportQueue()
        let backup = try XCTUnwrap(queue.appendBackupAssets(["a", "b", "c"], destinationID: UUID()))
        queue.update(backup) {
            $0.consumeNext()
            $0.counts.archivedCompleted = 1
            $0.counts.archivedBytes = 42
        }
        try store.save(queue)

        let loaded = PhotoExportQueueStore(directoryURL: directory).load()

        XCTAssertEqual(loaded, queue)
        XCTAssertEqual(loaded[backup]?.nextAssetID, "b")
        XCTAssertEqual(loaded[backup]?.counts.unstaged, 2)

        queue = PhotoExportQueue()
        try store.save(queue)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["batches.json"])
    }

    func testLedgerSurvivesRelaunchAndReset() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ledger-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let ledger = AutomaticBackupLedger(fileURL: fileURL)
        ledger.record("A/L0/001")
        ledger.record("B/L0/001")
        ledger.record("A/L0/001")
        XCTAssertEqual(AutomaticBackupLedger(fileURL: fileURL).assetIDs, ["A/L0/001", "B/L0/001"])

        ledger.reset(to: ["C/L0/001"])
        ledger.record("D/L0/001")
        XCTAssertEqual(AutomaticBackupLedger(fileURL: fileURL).assetIDs, ["C/L0/001", "D/L0/001"])
    }

    private func transfer(status: Transfer.Status, error: String? = nil) -> Transfer {
        Transfer(
            id: UUID(),
            filename: "IMG_0001.HEIC",
            byteCount: 10,
            createdAt: Date(),
            sourceCreationDate: nil,
            sourceModificationDate: Date(),
            destinationID: UUID(),
            batchID: UUID(),
            updatedAt: Date(),
            status: status,
            bytesTransferred: 0,
            attemptCount: 1,
            remoteFilename: nil,
            errorMessage: error
        )
    }
}
