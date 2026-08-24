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
