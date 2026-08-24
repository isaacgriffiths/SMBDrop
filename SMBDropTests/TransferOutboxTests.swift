import Foundation
import XCTest
@testable import SMBDrop

final class TransferOutboxTests: XCTestCase {
    private let destinationID = UUID()
    private let batchID = UUID()

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
            filename: "IMG_0001.HEIC",
            destinationID: destinationID,
            batchID: batchID
        )

        XCTAssertEqual(staged.filename, "IMG_0001.HEIC")
        XCTAssertEqual(staged.byteCount, Int64(bytes.count))
        XCTAssertEqual(staged.status, .queued)

        let restartedProcess = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        let claimed = try await restartedProcess.claimNext(for: destinationID)
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
        let staged = try await crashedProcess.enqueueFile(
            at: sourceURL,
            filename: "clip.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        let abandonedClaim = try await crashedProcess.claimNext(for: destinationID)
        let abandonedWork = try XCTUnwrap(abandonedClaim)

        let restartedProcess = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstClaimDate.addingTimeInterval(61) }
        )
        let recoveredClaim = try await restartedProcess.claimNext(for: destinationID)
        let recoveredWork = try XCTUnwrap(recoveredClaim)

        XCTAssertEqual(recoveredWork.transfer.id, staged.id)
        XCTAssertNotEqual(recoveredWork.claimID, abandonedWork.claimID)
        XCTAssertEqual(recoveredWork.transfer.attemptCount, 2)

        do {
            _ = try await crashedProcess.fail(
                abandonedWork,
                message: "This claimant no longer owns the Transfer."
            )
            XCTFail("An expired claimant must not mutate a reclaimed Transfer")
        } catch TransferOutboxError.claimNoLongerValid {
            // Expected: the restarted process owns the replacement claim.
        }
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

        let staged = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "document.pdf",
            destinationID: destinationID,
            batchID: batchID
        )
        let firstClaim = try await outbox.claimNext(for: destinationID)
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
        let claimWhileFailed = try await restartedProcess.claimNext(for: destinationID)
        XCTAssertNil(claimWhileFailed)

        let retried = try await restartedProcess.retry(staged.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertNil(retried.errorMessage)

        let secondClaim = try await restartedProcess.claimNext(for: destinationID)
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

        _ = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "archive.zip",
            destinationID: destinationID,
            batchID: batchID
        )
        let claim = try await outbox.claimNext(for: destinationID)
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
        let competingClaim = try await beforeRenewedLeaseExpires.claimNext(for: destinationID)
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

        let staged = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "IMG_0001.HEIC",
            destinationID: destinationID,
            batchID: batchID
        )
        let claim = try await outbox.claimNext(for: destinationID)
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
        let completedClaim = try await restartedProcess.claimNext(for: destinationID)
        XCTAssertNil(completedClaim)
    }

    func testRemovingTransferDeletesItsStagedPayloadAndHistory() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("notes.txt")
        try Data("private notes".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(
            rootURL: rootURL.appendingPathComponent("Outbox", isDirectory: true)
        )

        let staged = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "notes.txt",
            destinationID: destinationID,
            batchID: batchID
        )
        let claim = try await outbox.claimNext(for: destinationID)
        let work = try XCTUnwrap(claim)
        _ = try await outbox.fail(work, message: "The server is unavailable.")

        try await outbox.remove(staged.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: work.fileURL.path))
        let remainingTransfers = try await outbox.transfers()
        XCTAssertTrue(remainingTransfers.isEmpty)
    }

    func testRequestingRemovalOfQueuedTransferDeletesItImmediately() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("queued.mov")
        try Data("queued video".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(
            rootURL: rootURL.appendingPathComponent("Outbox", isDirectory: true)
        )
        let staged = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "queued.mov",
            destinationID: destinationID,
            batchID: batchID
        )

        let result = try await outbox.requestRemoval(staged.id)

        XCTAssertEqual(result, .removed)
        XCTAssertTrue(try await outbox.transfers().isEmpty)
    }

    func testRequestingRemovalOfUploadingTransferIsHonoredByItsOwner() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("sending.mov")
        try Data("sending video".utf8).write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let owner = TransferOutbox(rootURL: outboxURL)
        let staged = try await owner.enqueueFile(
            at: sourceURL,
            filename: "sending.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        let work = try XCTUnwrap(try await owner.claimNext(for: destinationID))
        let requester = TransferOutbox(rootURL: outboxURL)

        let result = try await requester.requestRemoval(staged.id)

        XCTAssertEqual(result, .cancellationRequested)
        XCTAssertTrue(work.isRemovalRequested)
        try await owner.removeClaimed(work)
        XCTAssertTrue(try await requester.transfers().isEmpty)
    }

    func testReleasingClaimedTransferMakesItQueuedAndClaimableAgain() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("paused.mov")
        try Data("paused video".utf8).write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let owner = TransferOutbox(rootURL: outboxURL)
        let staged = try await owner.enqueueFile(
            at: sourceURL,
            filename: "paused.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        let work = try XCTUnwrap(try await owner.claimNext(for: destinationID))

        let released = try await owner.release(work)
        let restarted = TransferOutbox(rootURL: outboxURL)
        let claimedAgain = try XCTUnwrap(try await restarted.claimNext(for: destinationID))

        XCTAssertEqual(released.status, .queued)
        XCTAssertEqual(released.bytesTransferred, 0)
        XCTAssertEqual(claimedAgain.transfer.id, staged.id)
    }

    func testConcurrentProcessesCannotClaimTheSameTransfer() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("shared.mov")
        try Data("one shared payload".utf8).write(to: sourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let stagingProcess = TransferOutbox(rootURL: outboxURL)
        let staged = try await stagingProcess.enqueueFile(
            at: sourceURL,
            filename: "shared.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        let contenders = (0..<32).map { _ in TransferOutbox(rootURL: outboxURL) }
        let claimDestinationID = destinationID

        let claims = try await withThrowingTaskGroup(of: TransferWork?.self) { group in
            for contender in contenders {
                group.addTask {
                    try await contender.claimNext(for: claimDestinationID)
                }
            }

            var claimedWork: [TransferWork] = []
            for try await claim in group {
                if let claim {
                    claimedWork.append(claim)
                }
            }
            return claimedWork
        }

        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.transfer.id, staged.id)
    }

    func testActiveTransferPreventsNextQueuedTransferFromStarting() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstSourceURL = rootURL.appendingPathComponent("first.mov")
        let secondSourceURL = rootURL.appendingPathComponent("second.mov")
        try Data("first payload".utf8).write(to: firstSourceURL)
        try Data("second payload".utf8).write(to: secondSourceURL)
        let outboxURL = rootURL.appendingPathComponent("Outbox", isDirectory: true)
        let firstProcess = TransferOutbox(rootURL: outboxURL)

        let first = try await firstProcess.enqueueFile(
            at: firstSourceURL,
            filename: "first.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        _ = try await firstProcess.enqueueFile(
            at: secondSourceURL,
            filename: "second.mov",
            destinationID: destinationID,
            batchID: batchID
        )
        let firstClaim = try await firstProcess.claimNext(for: destinationID)
        XCTAssertEqual(firstClaim?.transfer.id, first.id)

        let secondProcess = TransferOutbox(rootURL: outboxURL)
        let competingClaim = try await secondProcess.claimNext(for: destinationID)

        XCTAssertNil(competingClaim)
    }

    func testOriginalFilenameIsPreservedExactly() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source.pdf")
        try Data("original document bytes".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(
            rootURL: rootURL.appendingPathComponent("Outbox", isDirectory: true)
        )

        let staged = try await outbox.enqueueFile(
            at: sourceURL,
            filename: " Report final .pdf ",
            destinationID: destinationID,
            batchID: batchID
        )

        XCTAssertEqual(staged.filename, " Report final .pdf ")
        let persisted = try await outbox.transfers()
        XCTAssertEqual(persisted.first?.filename, " Report final .pdf ")
    }

    func testDestinationClaimOnlyReturnsFilesChosenForThatShare() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appendingPathComponent("first.txt")
        let secondURL = rootURL.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let firstDestinationID = UUID()
        let secondDestinationID = UUID()
        let outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))

        _ = try await outbox.enqueueFile(
            at: firstURL,
            filename: "first.txt",
            destinationID: firstDestinationID,
            batchID: UUID()
        )
        let second = try await outbox.enqueueFile(
            at: secondURL,
            filename: "second.txt",
            destinationID: secondDestinationID,
            batchID: UUID()
        )

        let claimed = try await outbox.claimNext(for: secondDestinationID)
        let work = try XCTUnwrap(claimed)

        XCTAssertEqual(work.transfer.id, second.id)
        XCTAssertEqual(work.transfer.destinationID, secondDestinationID)
    }

    func testLegacyUnassignedFilesCanBeBoundToAChosenDestination() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("legacy.txt")
        try Data("legacy".utf8).write(to: sourceURL)
        let destinationID = UUID()
        let outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        try stageLegacyTransfer(
            at: sourceURL,
            filename: "legacy.txt",
            outboxRootURL: rootURL.appendingPathComponent("Outbox")
        )

        try await outbox.assignUnassignedTransfers(to: destinationID)

        let claimed = try await outbox.claimNext(for: destinationID)
        let work = try XCTUnwrap(claimed)
        XCTAssertEqual(work.transfer.destinationID, destinationID)
        XCTAssertNotNil(work.transfer.batchID)
    }

    func testRetiredDestinationRejectsAStaleExtensionEnqueue() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))

        let retired = try await outbox.retireDestination(destinationID)
        XCTAssertTrue(retired)

        do {
            _ = try await outbox.enqueueFile(
                at: sourceURL,
                filename: "late.txt",
                destinationID: destinationID,
                batchID: batchID
            )
            XCTFail("A retired destination must reject stale extension work")
        } catch TransferOutboxError.destinationRemoved {
            // Expected.
        }
    }

    func testSavedDestinationRecoversFromInterruptedRemoval() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("recovered.txt")
        try Data("recovered".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        let previousSessionID = UUID()
        let currentSessionID = UUID()
        let retired = try await outbox.retireDestination(
            destinationID,
            ownerSessionID: previousSessionID
        )
        XCTAssertTrue(retired)

        try await outbox.reconcileRetiredDestinations(
            with: Set([destinationID]),
            currentSessionID: currentSessionID
        )
        let transfer = try await outbox.enqueueFile(
            at: sourceURL,
            filename: "recovered.txt",
            destinationID: destinationID,
            batchID: batchID
        )

        XCTAssertEqual(transfer.destinationID, destinationID)
    }

    func testCurrentRemovalCannotBeReconciledByConcurrentResume() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: sourceURL)
        let outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox"))
        let currentSessionID = UUID()
        let retired = try await outbox.retireDestination(
            destinationID,
            ownerSessionID: currentSessionID
        )
        XCTAssertTrue(retired)

        try await outbox.reconcileRetiredDestinations(
            with: Set([destinationID]),
            currentSessionID: currentSessionID
        )

        do {
            _ = try await outbox.enqueueFile(
                at: sourceURL,
                filename: "late.txt",
                destinationID: destinationID,
                batchID: batchID
            )
            XCTFail("A concurrent resume must not reopen a destination being removed")
        } catch TransferOutboxError.destinationRemoved {
            // Expected.
        }
    }

    private func stageLegacyTransfer(
        at sourceURL: URL,
        filename: String,
        outboxRootURL: URL
    ) throws {
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let id = UUID()
        let directoryURL = outboxRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceURL,
            to: directoryURL.appendingPathComponent("payload")
        )
        let transfer = Transfer(
            id: id,
            filename: filename,
            byteCount: Int64(values.fileSize ?? 0),
            createdAt: Date(),
            sourceCreationDate: values.creationDate,
            sourceModificationDate: values.contentModificationDate,
            destinationID: nil,
            batchID: nil,
            updatedAt: Date(),
            status: .queued,
            bytesTransferred: 0,
            attemptCount: 0,
            remoteFilename: nil,
            errorMessage: nil
        )
        try JSONEncoder().encode(transfer).write(
            to: directoryURL.appendingPathComponent("transfer.json"),
            options: .atomic
        )
    }
}
