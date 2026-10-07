import XCTest
@testable import SMBDrop

final class TransferBatchProgressTests: XCTestCase {
    func testOverallProgressCombinesCompletedAndCurrentItemBytes() {
        let batchID = UUID()
        let destinationID = UUID()
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transfers = [
            transfer(
                filename: "one.jpg",
                bytes: 100,
                status: .completed,
                bytesTransferred: 100,
                destinationID: destinationID,
                batchID: batchID,
                createdAt: startDate
            ),
            transfer(
                filename: "two.mov",
                bytes: 300,
                status: .uploading,
                bytesTransferred: 100,
                destinationID: destinationID,
                batchID: batchID,
                createdAt: startDate.addingTimeInterval(1)
            ),
            transfer(
                filename: "three.pdf",
                bytes: 100,
                status: .queued,
                bytesTransferred: 0,
                destinationID: destinationID,
                batchID: batchID,
                createdAt: startDate.addingTimeInterval(2)
            ),
        ]

        let progress = TransferBatchProgress(transfers: transfers)

        XCTAssertEqual(progress.completedCount, 1)
        XCTAssertEqual(progress.currentItemNumber, 2)
        XCTAssertEqual(progress.totalCount, 3)
        XCTAssertEqual(progress.bytesTransferred, 200)
        XCTAssertEqual(progress.totalBytes, 500)
        XCTAssertEqual(progress.fractionCompleted, 0.4, accuracy: 0.001)
        XCTAssertEqual(progress.countText, "2 of 3")
    }

    func testCurrentItemNumberUsesTheActiveItemsPositionAfterAnEarlierFailure() {
        let batchID = UUID()
        let destinationID = UUID()
        let startDate = Date()
        let failed = transfer(
            filename: "failed.jpg",
            bytes: 100,
            status: .failed,
            bytesTransferred: 50,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate
        )
        let uploading = transfer(
            filename: "uploading.mov",
            bytes: 300,
            status: .uploading,
            bytesTransferred: 100,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate.addingTimeInterval(1)
        )
        let queued = transfer(
            filename: "queued.pdf",
            bytes: 100,
            status: .queued,
            bytesTransferred: 0,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate.addingTimeInterval(2)
        )

        let progress = TransferBatchProgress(transfers: [failed, uploading, queued])

        XCTAssertEqual(progress.currentFilename, "uploading.mov")
        XCTAssertEqual(progress.currentItemNumber, 2)
        XCTAssertEqual(progress.countText, "2 of 3")
        XCTAssertEqual(progress.itemNumber(for: failed.id), 1)
        XCTAssertEqual(progress.itemNumber(for: uploading.id), 2)
        XCTAssertEqual(progress.itemNumber(for: queued.id), 3)
    }

    func testTerminalFailureFilenameAndCountReferToTheSameItem() {
        let batchID = UUID()
        let destinationID = UUID()
        let startDate = Date()
        let failed = transfer(
            filename: "failed.jpg",
            bytes: 100,
            status: .failed,
            bytesTransferred: 50,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate
        )
        let completed = transfer(
            filename: "completed.mov",
            bytes: 300,
            status: .completed,
            bytesTransferred: 300,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate.addingTimeInterval(1)
        )

        let progress = TransferBatchProgress(transfers: [failed, completed])

        XCTAssertEqual(progress.currentFilename, "failed.jpg")
        XCTAssertEqual(progress.currentItemNumber, 1)
        XCTAssertEqual(progress.countText, "1 of 2")
    }

    func testChunkedBatchCountsArchivedAndUnstagedPhotos() {
        let batchID = UUID()
        let destinationID = UUID()
        let startDate = Date()
        let sent = transfer(
            filename: "sent.heic",
            bytes: 100,
            status: .completed,
            bytesTransferred: 100,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate
        )
        let sending = transfer(
            filename: "sending.heic",
            bytes: 100,
            status: .uploading,
            bytesTransferred: 50,
            destinationID: destinationID,
            batchID: batchID,
            createdAt: startDate.addingTimeInterval(1)
        )

        let progress = TransferBatchProgress(
            transfers: [sent, sending],
            chunked: ChunkedBatchCounts(
                unstaged: 6,
                archivedCompleted: 40,
                archivedBytes: 4_000,
                failedToStage: 2
            )
        )

        XCTAssertEqual(progress.totalCount, 50)
        XCTAssertEqual(progress.completedCount, 41)
        XCTAssertEqual(progress.failedCount, 2)
        XCTAssertEqual(progress.currentItemNumber, 42)
        XCTAssertEqual(progress.itemNumber(for: sending.id), 42)
        XCTAssertEqual(progress.bytesTransferred, 4_150)
        // Unstaged photos have no size yet, so the bar counts items.
        XCTAssertEqual(progress.fractionCompleted, 41.0 / 50.0, accuracy: 0.001)
        XCTAssertFalse(progress.isComplete)
    }

    func testBetweenChunksTheNextUnstagedPhotoIsCurrent() {
        let progress = TransferBatchProgress(
            transfers: [],
            chunked: ChunkedBatchCounts(unstaged: 30, archivedCompleted: 20, archivedBytes: 2_000)
        )

        XCTAssertEqual(progress.countText, "21 of 50")
        XCTAssertNil(progress.currentFilename)
    }

    func testAFullyArchivedBatchReadsAsComplete() {
        let progress = TransferBatchProgress(
            transfers: [],
            chunked: ChunkedBatchCounts(archivedCompleted: 20, archivedBytes: 2_000)
        )

        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.countText, "20 of 20")
        XCTAssertEqual(progress.fractionCompleted, 1)
    }

    private func transfer(
        filename: String,
        bytes: Int64,
        status: Transfer.Status,
        bytesTransferred: Int64,
        destinationID: UUID,
        batchID: UUID,
        createdAt: Date = Date()
    ) -> Transfer {
        Transfer(
            id: UUID(),
            filename: filename,
            byteCount: bytes,
            createdAt: createdAt,
            sourceCreationDate: nil,
            sourceModificationDate: Date(),
            destinationID: destinationID,
            batchID: batchID,
            updatedAt: Date(),
            status: status,
            bytesTransferred: bytesTransferred,
            attemptCount: 1,
            remoteFilename: nil,
            errorMessage: nil
        )
    }
}
