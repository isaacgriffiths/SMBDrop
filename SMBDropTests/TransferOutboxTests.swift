import Foundation
import XCTest
@testable import SMBDrop

final class TransferOutboxTests: XCTestCase {
    func testStagedFileSurvivesRestartAndIsNextToUpload() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source.heic")
        let bytes = Data("original photo bytes".utf8)
        try bytes.write(to: sourceURL)

        let firstProcess = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        let staged = try await firstProcess.enqueueFile(
            at: sourceURL,
            filename: "IMG_0001.HEIC"
        )

        XCTAssertEqual(staged.filename, "IMG_0001.HEIC")
        XCTAssertEqual(staged.byteCount, Int64(bytes.count))
        XCTAssertEqual(staged.status, .queued)

        let restartedProcess = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        let claimed = try await restartedProcess.claimNext()
        let work = try XCTUnwrap(claimed)

        XCTAssertEqual(work.transfer.id, staged.id)
        XCTAssertEqual(work.transfer.status, .uploading)
        XCTAssertEqual(try Data(contentsOf: work.fileURL), bytes)
    }

    func testTransferClaimedByCrashedProcessBecomesClaimableAfterLeaseExpires() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source.mov")
        try Data("original video bytes".utf8).write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let firstClaimDate = Date(timeIntervalSince1970: 1_000)

        let crashedProcess = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstClaimDate }
        )
        let staged = try await crashedProcess.enqueueFile(at: sourceURL, filename: "clip.mov")
        let abandonedClaim = try await crashedProcess.claimNext()
        let abandonedWork = try XCTUnwrap(abandonedClaim)

        let restartedProcess = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstClaimDate.addingTimeInterval(61) }
        )
        let recoveredClaim = try await restartedProcess.claimNext()
        let recoveredWork = try XCTUnwrap(recoveredClaim)

        XCTAssertEqual(recoveredWork.transfer.id, staged.id)
        XCTAssertNotEqual(recoveredWork.claimID, abandonedWork.claimID)
        XCTAssertEqual(recoveredWork.transfer.attemptCount, 2)
    }

    func testFailedTransferKeepsItsErrorAndCanBeRetried() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("document.pdf")
        try Data("original document bytes".utf8).write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let outbox = TransferOutbox(rootURL: outboxURL)

        let staged = try await outbox.enqueueFile(at: sourceURL, filename: "document.pdf")
        let firstClaim = try await outbox.claimNext()
        let work = try XCTUnwrap(firstClaim)
        let failed = try await outbox.fail(work, message: "The share stopped responding.")

        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorMessage, "The share stopped responding.")

        let restartedProcess = TransferOutbox(rootURL: outboxURL)
        let persistedTransfers = try await restartedProcess.transfers()
        let persisted = try XCTUnwrap(persistedTransfers.first)
        XCTAssertEqual(persisted.id, staged.id)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertEqual(persisted.errorMessage, "The share stopped responding.")
        let claimWhileFailed = try await restartedProcess.claimNext()
        XCTAssertNil(claimWhileFailed)

        let retried = try await restartedProcess.retry(staged.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertNil(retried.errorMessage)

        let secondClaim = try await restartedProcess.claimNext()
        let reclaimed = try XCTUnwrap(secondClaim)
        XCTAssertEqual(reclaimed.transfer.id, staged.id)
        XCTAssertEqual(reclaimed.transfer.attemptCount, 2)
    }

    func testProgressPersistsAndRenewsTheActiveClaim() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("archive.zip")
        let bytes = Data("original archive bytes".utf8)
        try bytes.write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let firstDate = Date(timeIntervalSince1970: 2_000)
        let outbox = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstDate }
        )

        _ = try await outbox.enqueueFile(at: sourceURL, filename: "archive.zip")
        let claim = try await outbox.claimNext()
        let work = try XCTUnwrap(claim)
        let uploadingProcess = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstDate.addingTimeInterval(30) }
        )
        let progress = try await uploadingProcess.updateProgress(work, bytesTransferred: 8)

        XCTAssertEqual(progress.status, .uploading)
        XCTAssertEqual(progress.bytesTransferred, 8)

        let beforeRenewedLeaseExpires = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstDate.addingTimeInterval(61) }
        )
        let competingClaim = try await beforeRenewedLeaseExpires.claimNext()
        XCTAssertNil(competingClaim)
        let persisted = try await beforeRenewedLeaseExpires.transfers()
        XCTAssertEqual(persisted.first?.bytesTransferred, 8)
    }

    func testCompletedTransferKeepsHistoryAndDeletesStagedPayload() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("IMG_0001.HEIC")
        let bytes = Data("original photo bytes".utf8)
        try bytes.write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let outbox = TransferOutbox(rootURL: outboxURL)

        let staged = try await outbox.enqueueFile(at: sourceURL, filename: "IMG_0001.HEIC")
        let claim = try await outbox.claimNext()
        let work = try XCTUnwrap(claim)
        let completed = try await outbox.complete(
            work,
            remoteFilename: "IMG_0001 (2).HEIC"
        )

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.bytesTransferred, Int64(bytes.count))
        XCTAssertEqual(completed.remoteFilename, "IMG_0001 (2).HEIC")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.fileURL.path))

        let restartedProcess = TransferOutbox(rootURL: outboxURL)
        let history = try await restartedProcess.transfers()
        XCTAssertEqual(history.map(\.id), [staged.id])
        XCTAssertEqual(history.first?.status, .completed)
        let completedClaim = try await restartedProcess.claimNext()
        XCTAssertNil(completedClaim)
    }
}
