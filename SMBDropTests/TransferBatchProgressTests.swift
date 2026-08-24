import XCTest
@testable import SMBDrop

final class TransferBatchProgressTests: XCTestCase {
    func testOverallProgressCombinesCompletedAndCurrentItemBytes() {
        let batchID = UUID()
        let destinationID = UUID()
        let transfers = [
            transfer(
                filename: "one.jpg",
                bytes: 100,
                status: .completed,
                bytesTransferred: 100,
                destinationID: destinationID,
                batchID: batchID
            ),
            transfer(
                filename: "two.mov",
                bytes: 300,
                status: .uploading,
                bytesTransferred: 100,
                destinationID: destinationID,
                batchID: batchID
            ),
            transfer(
                filename: "three.pdf",
                bytes: 100,
                status: .queued,
                bytesTransferred: 0,
                destinationID: destinationID,
                batchID: batchID
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

    private func transfer(
        filename: String,
        bytes: Int64,
        status: Transfer.Status,
        bytesTransferred: Int64,
        destinationID: UUID,
        batchID: UUID
    ) -> Transfer {
        Transfer(
            id: UUID(),
            filename: filename,
            byteCount: bytes,
            createdAt: Date(),
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
