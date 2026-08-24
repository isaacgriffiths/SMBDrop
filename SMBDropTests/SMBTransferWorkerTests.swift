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
            progress: { _ in }
        )

        XCTAssertEqual(remoteFilename, "clip.mov")
        XCTAssertEqual(work.transfer.sourceCreationDate, sourceDates.creationDate)
        XCTAssertEqual(
            work.transfer.sourceModificationDate,
            sourceDates.contentModificationDate
        )
        XCTAssertEqual(
            session.uploadedPath,
            "/video/.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.smbdrop-partial"
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
                progress: { _ in }
            )
            XCTFail("Expected an existing filename to stop the upload")
        } catch {
            XCTAssertEqual(error as? TransferUploadError, .fileAlreadyExists("clip.mov"))
        }

        XCTAssertNil(session.uploadedPath)
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
            password: "secret"
        )

        XCTAssertNil(result.failed)
        XCTAssertEqual(result.completed.map(\.id), [staged.id])
        XCTAssertEqual(result.completed.first?.status, .completed)
        XCTAssertEqual(result.completed.first?.bytesTransferred, staged.byteCount)
        let history = try await fixture.outbox.transfers()
        XCTAssertEqual(history.first?.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.payloadPath(for: staged.id)))
    }
}

private final class UploadFixture {
    let rootURL: URL
    let sourceURL: URL
    let filename: String
    let outbox: TransferOutbox

    init(filename: String, bytes: Data) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = rootURL.appendingPathComponent("source", isDirectory: false)
        try bytes.write(to: sourceURL)
        self.filename = filename
        outbox = TransferOutbox(rootURL: rootURL.appendingPathComponent("Outbox", isDirectory: true))
    }

    func enqueue() async throws -> Transfer {
        try await outbox.enqueueFile(at: sourceURL, filename: filename)
    }

    func claimedWork() async throws -> TransferWork {
        _ = try await enqueue()
        let work = try await outbox.claimNext()
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
    private let existingNames: [String]

    init(existingNames: [String]) {
        self.existingNames = existingNames
    }

    func connectShare(name: String, encrypted: Bool) async throws {}

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]] {
        existingNames.map { [.nameKey: $0] }
    }

    func uploadItem(
        at localURL: URL,
        toPath remotePath: String,
        progress: @escaping @Sendable (Int64) -> Bool
    ) async throws {
        uploadedPath = remotePath
        uploadedBytes = try Data(contentsOf: localURL)
        _ = progress(Int64(uploadedBytes?.count ?? 0))
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

    func removeFile(atPath path: String) async throws {}

    func disconnectShare(gracefully: Bool) async throws {
        disconnectModes.append(gracefully)
    }
}

private struct FakeTransferUploader: SMBTransferUploading {
    let remoteFilename: String

    func upload(
        _ work: TransferWork,
        to destination: Destination,
        password: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        progress(work.transfer.byteCount)
        return remoteFilename
    }
}
