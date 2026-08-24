import UniformTypeIdentifiers
import XCTest
@testable import SMBDrop

final class ShareItemFileStagerTests: XCTestCase {
    func testStagingPreservesOriginalNameBytesAndFileDates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("IMG_4523.MOV")
        let bytes = Data("original video bytes".utf8)
        try bytes.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: sourceURL.path
        )
        let sourceDates = try sourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )

        let staged = try ShareItemFileStager.stage(
            sourceURL: sourceURL,
            suggestedName: nil,
            typeIdentifier: UTType.quickTimeMovie.identifier
        )
        defer { try? FileManager.default.removeItem(at: staged.temporaryURL.deletingLastPathComponent()) }
        let stagedDates = try staged.temporaryURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )

        XCTAssertEqual(staged.filename, "IMG_4523.MOV")
        XCTAssertEqual(try Data(contentsOf: staged.temporaryURL), bytes)
        XCTAssertEqual(stagedDates.creationDate, sourceDates.creationDate)
        XCTAssertEqual(stagedDates.contentModificationDate, sourceDates.contentModificationDate)
    }
}
