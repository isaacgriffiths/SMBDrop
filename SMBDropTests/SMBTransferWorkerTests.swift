import Foundation
import XCTest
@testable import SMBDrop

final class SMBTransferWorkerTests: XCTestCase {
    func testUploaderPreservesNameAndDatesWhenPublishingAtomically() async throws {
        let fixture = try UploadFixture(filename: "clip.mov", bytes: Data("video bytes".utf8))
        defer { fixture.remove() }
        let work = try await fixture.claimedWork()
        let sourceDates = try fixture.sourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let session = FakeUploadSession(existingNames: [])
        let fixedUUID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let uploader = SMBTransferUploader(
            sessionFactory: { _, _ in session },
            makeUUID: { fixedUUID }
        )
        let destination = try Destination(
            host: "192.168.1.122",
            share: "share",
            subfolder: "video",
            username: "isaac"
        )

        let remoteFilename = try await uploader.upload(
            work,
            to: destination,
            password: "secret",
            progress: { _ in },
            shouldPublish: { true }
        )

        XCTAssertEqual(remoteFilename, "clip.mov")
        XCTAssertEqual(work.transfer.sourceCreationDate, sourceDates.creationDate)
        XCTAssertEqual(
            work.transfer.sourceModificationDate,
            sourceDates.contentModificationDate
        )
        XCTAssertEqual(
            session.uploadedPath,
            "/video/smbdrop-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.partial"
        )
        XCTAssertEqual(session.movedFromPath, session.uploadedPath)
        XCTAssertEqual(session.attributesPath, session.uploadedPath)
        XCTAssertEqual(
            session.writtenAttributes?[.creationDateKey] as? Date,
            work.transfer.sourceCreationDate
        )
        XCTAssertEqual(
            session.writtenAttributes?[.contentModificationDateKey] as? Date,
            work.transfer.sourceModificationDate
        )
        XCTAssertEqual(session.movedToPath, "/video/clip.mov")
        XCTAssertEqual(session.uploadedBytes, Data("video bytes".utf8))
        XCTAssertEqual(session.disconnectModes, [true])
    }

    func testUploaderRejectsAnExistingNameInsteadOfChangingOrOverwritingIt() async throws {
        let fixture = try UploadFixture(filename: "clip.mov", bytes: Data("video bytes".utf8))
        defer { fixture.remove() }
        let work = try await fixture.claimedWork()
        let session = FakeUploadSession(existingNames: ["CLIP.MOV"])
        let uploader = SMBTransferUploader(sessionFactory: { _, _ in session })
        let destination = try Destination(
            host: "192.168.1.122",
            share: "share",
            subfolder: "Video",
            username: "isaac"
        )

        do {
            _ = try await uploader.upload(
                work,
                to: destination,
                password: "secret",
                progress: { _ in },
                shouldPublish: { true }
            )
            XCTFail("Expected an existing filename to stop the upload")
        } catch {
            XCTAssertEqual(error as? TransferUploadError, .fileAlreadyExists("clip.mov"))
        }

        XCTAssertNil(session.uploadedPath)
        XCTAssertEqual(session.disconnectModes, [false])
    }

    func testBackupTreatsAnIdenticalExistingFileAsAlreadyUploaded() async throws {
        let bytes = Data("photo bytes".utf8)
        let fixture = try UploadFixture(filename: "IMG_0001.HEIC", bytes: bytes)
        defer { fixture.remove() }
        let work = try await fixture.claimedWork(acceptsIdenticalExistingFile: true)
        let session = FakeUploadSession(
            existingNames: ["IMG_0001.HEIC"],
            existingSizes: ["IMG_0001.HEIC": bytes.count]
        )
        let uploader = SMBTransferUploader(sessionFactory: { _, _ in session })
        let destination = try Destination(host: "nas", share: "photos", subfolder: "", username: "isaac")
        let reservation = PublishReservation()

        let remoteFilename = try await uploader.upload(
            work,
            to: destination,
            password: "secret",
            progress: { _ in },
            shouldPublish: {
                reservation.wasRequested = true
                return true
            }
        )

        XCTAssertEqual(remoteFilename, "IMG_0001.HEIC")
        XCTAssertTrue(reservation.wasRequested)
        XCTAssertNil(session.uploadedPath)
        XCTAssertNil(session.movedToPath)
    }

    func testBackupStillStopsWhenTheExistingFileDiffers() async throws {
        let bytes = Data("photo bytes".utf8)
        for (existingName, existingSize) in [
            ("IMG_0001.HEIC", bytes.count + 1),
            ("img_0001.heic", bytes.count),
        ] {
            let fixture = try UploadFixture(filename: "IMG_0001.HEIC", bytes: bytes)
            defer { fixture.remove() }
            let work = try await fixture.claimedWork(acceptsIdenticalExistingFile: true)
            let session = FakeUploadSession(
                existingNames: [existingName],
                existingSizes: [existingName: existingSize]
            )
            let uploader = SMBTransferUploader(sessionFactory: { _, _ in session })
            let destination = try Destination(host: "nas", share: "photos", subfolder: "", username: "isaac")

            do {
                _ = try await uploader.upload(
                    work,
                    to: destination,
                    password: "secret",
                    progress: { _ in },
                    shouldPublish: { true }
                )
                XCTFail("Expected \(existingName) (\(existingSize) bytes) to stop the upload")
            } catch {
                XCTAssertEqual(error as? TransferUploadError, .fileAlreadyExists("IMG_0001.HEIC"))
            }
            XCTAssertNil(session.uploadedPath)
        }
    }

    func testOnlyNameClashesCountAsItemSpecificFailures() {
        var transfer = Transfer(
            id: UUID(),
            filename: "IMG_0001.HEIC",
            byteCount: 10,
            createdAt: Date(),
            sourceCreationDate: nil,
            sourceModificationDate: Date(),
            destinationID: UUID(),
            batchID: UUID(),
            updatedAt: Date(),
            status: .failed,
            bytesTransferred: 0,
            attemptCount: 1,
            remoteFilename: nil,
            errorMessage: TransferUploadError.fileAlreadyExists("IMG_0001.HEIC").errorDescription
        )
        XCTAssertTrue(transfer.hasItemSpecificFailure)

        transfer.errorMessage = SMBConnectionError.serverUnavailable.errorDescription
        XCTAssertFalse(transfer.hasItemSpecificFailure)
    }

    func testUploaderStopsAndRemovesPartialWhenTransferRemovalIsRequested() async throws {
        let fixture = try UploadFixture(filename: "clip.mov", bytes: Data("video bytes".utf8))
        defer { fixture.remove() }
        let work = try await fixture.claimedWork()
        let session = FakeUploadSession(
            existingNames: [],
            beforeProgress: {
                _ = try await fixture.outbox.requestRemoval(work.transfer.id)
            }
        )
        let uploader = SMBTransferUploader(sessionFactory: { _, _ in session })
        let destination = try Destination(
            host: "192.168.1.122",
            share: "share",
            subfolder: "Video",
            username: "isaac"
        )

        do {
            _ = try await uploader.upload(
                work,
                to: destination,
                password: "secret",
                progress: { _ in },
                shouldPublish: { true }
            )
            XCTFail("A removal request must stop before the partial file is published")
        } catch {
            XCTAssertEqual(error as? TransferUploadError, .cancelled)
        }

        XCTAssertEqual(session.removedPaths, [session.uploadedPath])
        XCTAssertNil(session.movedToPath)
        XCTAssertEqual(session.disconnectModes, [false])
    }

    func testWorkerCompletesDurableTransferAndRemovesStagedPayload() async throws {
        let fixture = try UploadFixture(filename: "IMG_0001.HEIC", bytes: Data("photo bytes".utf8))
        defer { fixture.remove() }
        let staged = try await fixture.enqueue()
        let uploader = FakeTransferUploader(remoteFilename: "IMG_0001.HEIC")
        let worker = SMBTransferWorker(uploader: uploader)
        let destination = try Destination(
            host: "nas.local",
            share: "share",
            subfolder: "video",
            username: "isaac"
        )

        let result = await worker.drain(
            outbox: fixture.outbox,
            destination: destination,
            password: "secret",
            destinationID: fixture.destinationID
        )

        XCTAssertNil(result.failed)
        XCTAssertEqual(result.completed.map(\.id), [staged.id])
        XCTAssertEqual(result.completed.first?.status, .completed)
        XCTAssertEqual(result.completed.first?.bytesTransferred, staged.byteCount)
        let history = try await fixture.outbox.transfers()
        XCTAssertEqual(history.first?.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.payloadPath(for: staged.id)))
    }

    func testWorkerRemovesTransferWhenUploaderObservesRemovalRequest() async throws {
        let fixture = try UploadFixture(filename: "remove.mov", bytes: Data("video bytes".utf8))
        defer { fixture.remove() }
        let staged = try await fixture.enqueue()
        let worker = SMBTransferWorker(
            uploader: RemovalRequestingUploader(outbox: fixture.outbox)
        )
        let destination = try Destination(
            host: "nas.local",
            share: "share",
            subfolder: "Video",
            username: "isaac"
        )

        let result = await worker.drain(
            outbox: fixture.outbox,
            destination: destination,
            password: "secret",
            destinationID: fixture.destinationID
        )

        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertNil(result.failed)
        let remainingTransfers = try await fixture.outbox.transfers()
        XCTAssertTrue(remainingTransfers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.payloadPath(for: staged.id)))
    }
}

private final class UploadFixture {
    let rootURL: URL
    let sourceURL: URL
    let filename: String
    let outbox: TransferOutbox
    let destinationID = UUID()
    let batchID = UUID()

    init(filename: String, bytes: Data) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = rootURL.appendingPathComponent("source", isDirectory: false)
        try bytes.write(to: sourceURL)
        self.filename = filename
        outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox", isDirectory: true))
    }

    func enqueue(acceptsIdenticalExistingFile: Bool = false) async throws -> Transfer {
        try await outbox.enqueueFile(
            at: sourceURL,
            filename: filename,
            destinationID: destinationID,
            batchID: batchID,
            acceptsIdenticalExistingFile: acceptsIdenticalExistingFile
        )
    }

    func claimedWork(acceptsIdenticalExistingFile: Bool = false) async throws -> TransferWork {
        _ = try await enqueue(acceptsIdenticalExistingFile: acceptsIdenticalExistingFile)
        let work = try await outbox.claimNext(for: destinationID)
        return try XCTUnwrap(work)
    }

    func payloadPath(for id: UUID) -> String {
        rootURL.appendingPathComponent("Outbox/\(id.uuidString)/payload").path
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class FakeUploadSession: SMBUploadSession {
    var timeout: TimeInterval = 0
    var uploadedPath: String?
    var uploadedBytes: Data?
    var movedFromPath: String?
    var movedToPath: String?
    var attributesPath: String?
    var writtenAttributes: [URLResourceKey: Any]?
    var disconnectModes: [Bool] = []
    var removedPaths: [String] = []
    private let existingNames: [String]
    private let existingSizes: [String: Int]
    private let beforeProgress: (() async throws -> Void)?

    init(
        existingNames: [String],
        existingSizes: [String: Int] = [:],
        beforeProgress: (() async throws -> Void)? = nil
    ) {
        self.existingNames = existingNames
        self.existingSizes = existingSizes
        self.beforeProgress = beforeProgress
    }

    func connectShare(name: String, encrypted: Bool) async throws {}

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]] {
        existingNames.map { name in
            var entry: [URLResourceKey: Any] = [.nameKey: name]
            entry[.fileSizeKey] = existingSizes[name].map(NSNumber.init(value:))
            return entry
        }
    }

    func uploadItem(
        at localURL: URL,
        toPath remotePath: String,
        progress: @escaping @Sendable (Int64) -> Bool
    ) async throws {
        uploadedPath = remotePath
        uploadedBytes = try Data(contentsOf: localURL)
        try await beforeProgress?()
        guard progress(Int64(uploadedBytes?.count ?? 0)) else {
            throw FakeUploadError.stopped
        }
    }

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        [.fileSizeKey: uploadedBytes?.count ?? 0]
    }

    func setAttributes(
        _ attributes: [URLResourceKey: Any],
        ofItemAtPath path: String
    ) async throws {
        attributesPath = path
        writtenAttributes = attributes
    }

    func moveItem(atPath path: String, toPath: String) async throws {
        movedFromPath = path
        movedToPath = toPath
    }

    func removeFile(atPath path: String) async throws {
        removedPaths.append(path)
    }

    func disconnectShare(gracefully: Bool) async throws {
        disconnectModes.append(gracefully)
    }
}

private final class PublishReservation: @unchecked Sendable {
    var wasRequested = false
}

private enum FakeUploadError: Error {
    case stopped
}

private struct FakeTransferUploader: SMBTransferUploading {
    let remoteFilename: String

    func upload(
        _ work: TransferWork,
        to destination: Destination,
        password: String,
        progress: @escaping @Sendable (Int64) -> Void,
        shouldPublish: @escaping @Sendable () async throws -> Bool
    ) async throws -> String {
        progress(work.transfer.byteCount)
        guard try await shouldPublish() else {
            throw TransferUploadError.cancelled
        }
        return remoteFilename
    }
}

private struct RemovalRequestingUploader: SMBTransferUploading {
    let outbox: TransferOutbox

    func upload(
        _ work: TransferWork,
        to destination: Destination,
        password: String,
        progress: @escaping @Sendable (Int64) -> Void,
        shouldPublish: @escaping @Sendable () async throws -> Bool
    ) async throws -> String {
        _ = try await outbox.requestRemoval(work.transfer.id)
        throw TransferUploadError.cancelled
    }
}
