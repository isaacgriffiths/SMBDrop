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
        let work = try XCTUnwrap(try await restartedProcess.claimNext())

        XCTAssertEqual(work.transfer.id, staged.id)
        XCTAssertEqual(work.transfer.status, .uploading)
        XCTAssertEqual(try Data(contentsOf: work.fileURL), bytes)
    }
}
