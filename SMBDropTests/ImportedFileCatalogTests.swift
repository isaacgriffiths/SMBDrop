import XCTest
@testable import SMBDrop

final class ImportedFileCatalogTests: XCTestCase {
    func testCatalogReturnsPastImportsNewestFirstWithMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDrop-Imports-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let olderURL = directory.appendingPathComponent("scan.pdf")
        let newerURL = directory.appendingPathComponent("photo.jpg")
        try Data(repeating: 1, count: 12).write(to: olderURL)
        try Data(repeating: 2, count: 24).write(to: newerURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: olderURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newerURL.path
        )

        let items = try ImportedFileCatalog(directoryURL: directory).items()

        XCTAssertEqual(items.map(\.name), ["photo.jpg", "scan.pdf"])
        XCTAssertEqual(items.map(\.byteCount), [24, 12])
        XCTAssertEqual(items.map(\.kind), [.image, .document])
    }

    func testCatalogHidesPartialAndHiddenWorkingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDrop-Imports-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent("ready.mov"))
        try Data().write(to: directory.appendingPathComponent("smbdrop-work.partial"))
        try Data().write(to: directory.appendingPathComponent(".metadata"))

        let items = try ImportedFileCatalog(directoryURL: directory).items()

        XCTAssertEqual(items.map(\.name), ["ready.mov"])
        XCTAssertEqual(items.first?.kind, .video)
    }
}
