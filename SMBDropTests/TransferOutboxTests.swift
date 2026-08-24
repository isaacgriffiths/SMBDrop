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
        let abandonedWork = try XCTUnwrap(try await crashedProcess.claimNext())

        let restartedProcess = TransferOutbox(
            rootURL: outboxURL,
            claimLeaseDuration: 60,
            now: { firstClaimDate.addingTimeInterval(61) }
        )
        let recoveredWork = try XCTUnwrap(try await restartedProcess.claimNext())

        XCTAssertEqual(recoveredWork.transfer.id, staged.id)
        XCTAssertNotEqual(recoveredWork.claimID, abandonedWork.claimID)
        XCTAssertEqual(recoveredWork.transfer.attemptCount, 2)
    }
}
