import Foundation
import XCTest
@testable import SMBDrop

final class SMBImportServiceTests: XCTestCase {
    func testBrowsingSavedShareStartsAtConfiguredFolderAndPresentsFoldersBeforeFiles() async throws {
        let fixture = try ImportFixture()
        fixture.session.directoryEntries["/Phone"] = [
            [
                .nameKey: "clip.mov",
                .isDirectoryKey: false,
                .fileSizeKey: NSNumber(value: 42),
            ],
            [
                .nameKey: "Trips",
                .isDirectoryKey: true,
            ],
            [
                .nameKey: "cover.jpg",
                .isDirectoryKey: false,
                .fileSizeKey: NSNumber(value: 12),
            ],
        ]

        let items = try await fixture.service.contents(
            of: fixture.saved.id,
            at: ""
        )

        XCTAssertEqual(items.map(\.name), ["Trips", "clip.mov", "cover.jpg"])
        XCTAssertEqual(items.map(\.relativePath), ["Trips", "clip.mov", "cover.jpg"])
        XCTAssertEqual(items.map(\.isDirectory), [true, false, false])
        XCTAssertEqual(fixture.session.connectedShares, ["Photos"])
        XCTAssertEqual(fixture.session.requestedDirectoryPaths, ["/Phone"])
        XCTAssertEqual(fixture.session.gracefulDisconnects, [true])
    }

    func testImportDownloadsOriginalBytesIntoTheOnDeviceImportsFolder() async throws {
        let fixture = try ImportFixture()
        let payload = Data("original smb bytes".utf8)
        fixture.session.downloadPayloads["/Phone/clip.mov"] = payload
        let item = SMBRemoteItem(
            name: "clip.mov",
            relativePath: "clip.mov",
            isDirectory: false,
            byteCount: Int64(payload.count),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let progress = ImportProgressRecorder()

        let imported = try await fixture.service.importItems(
            [item],
            from: fixture.saved.id
        ) { update in
            progress.record(update)
        }

        let localURL = try XCTUnwrap(imported.first)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(localURL.deletingLastPathComponent(), fixture.importDirectory)
        XCTAssertEqual(localURL.lastPathComponent, "clip.mov")
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        let importedDate = try localURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        XCTAssertEqual(
            try XCTUnwrap(importedDate).timeIntervalSince1970,
            1_700_000_000,
            accuracy: 1
        )
        XCTAssertEqual(fixture.session.requestedDownloadPaths, ["/Phone/clip.mov"])
        XCTAssertEqual(progress.values.last?.completedItemCount, 1)
        XCTAssertEqual(progress.values.last?.totalItemCount, 1)
        XCTAssertEqual(progress.values.last?.bytesTransferred, Int64(payload.count))
    }

    func testImportNeverOverwritesAnExistingOnDeviceFile() async throws {
        let fixture = try ImportFixture()
        try FileManager.default.createDirectory(
            at: fixture.importDirectory,
            withIntermediateDirectories: true
        )
        let existingURL = fixture.importDirectory.appendingPathComponent("clip.mov")
        let existingBytes = Data("keep me".utf8)
        try existingBytes.write(to: existingURL)
        let item = SMBRemoteItem(
            name: "clip.mov",
            relativePath: "clip.mov",
            isDirectory: false,
            byteCount: 100,
            modificationDate: nil
        )

        do {
            _ = try await fixture.service.importItems(
                [item],
                from: fixture.saved.id,
                progress: { _ in }
            )
            XCTFail("Import should stop before overwriting an existing file.")
        } catch {
            XCTAssertEqual(error as? SMBImportError, .fileAlreadyExists("clip.mov"))
        }

        XCTAssertEqual(try Data(contentsOf: existingURL), existingBytes)
        XCTAssertTrue(fixture.session.requestedDownloadPaths.isEmpty)
    }

    func testImportRemovesAPartialFileWhenTheDownloadedSizeDoesNotMatch() async throws {
        let fixture = try ImportFixture()
        fixture.session.downloadPayloads["/Phone/clip.mov"] = Data("short".utf8)
        let item = SMBRemoteItem(
            name: "clip.mov",
            relativePath: "clip.mov",
            isDirectory: false,
            byteCount: 100,
            modificationDate: nil
        )

        do {
            _ = try await fixture.service.importItems(
                [item],
                from: fixture.saved.id,
                progress: { _ in }
            )
            XCTFail("A truncated download must not be published.")
        } catch {
            XCTAssertEqual(error as? SMBImportError, .sizeMismatch("clip.mov"))
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.importDirectory.path),
            []
        )
        XCTAssertEqual(fixture.session.gracefulDisconnects, [false])
    }

    func testPartialFailureReportsCompletedFilesSoOnlyUnfinishedItemsNeedRetrying() async throws {
        let fixture = try ImportFixture()
        let firstBytes = Data("first".utf8)
        fixture.session.downloadPayloads["/Phone/first.mov"] = firstBytes
        fixture.session.failingDownloadPaths = ["/Phone/second.mov"]
        let items = [
            SMBRemoteItem(
                name: "first.mov",
                relativePath: "first.mov",
                isDirectory: false,
                byteCount: Int64(firstBytes.count),
                modificationDate: nil
            ),
            SMBRemoteItem(
                name: "second.mov",
                relativePath: "second.mov",
                isDirectory: false,
                byteCount: 20,
                modificationDate: nil
            ),
        ]

        do {
            _ = try await fixture.service.importItems(
                items,
                from: fixture.saved.id,
                progress: { _ in }
            )
            XCTFail("The batch should report its completed prefix when a later file fails.")
        } catch let error as SMBImportPartialFailure {
            XCTAssertEqual(error.importedItems.map(\.id), ["first.mov"])
            XCTAssertEqual(error.importedURLs.map(\.lastPathComponent), ["first.mov"])
            XCTAssertEqual(error.totalItemCount, 2)
        } catch {
            XCTFail("Expected a partial import failure, got \(error)")
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.importDirectory.appendingPathComponent("first.mov")),
            firstBytes
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.importDirectory.path),
            ["first.mov"]
        )
    }
}

private struct ImportFixture {
    let saved: SavedDestination
    let session: ImportSession
    let service: SMBImportService
    let importDirectory: URL

    init() throws {
        let suiteName = "SMBDropImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = DestinationStore(
            defaults: defaults,
            passwordVault: ImportMemoryPasswordVault()
        )
        let saved = try store.save(
            destination: Destination(
                host: "nas.local",
                share: "Photos",
                subfolder: "Phone",
                username: "isaac"
            ),
            password: "secret"
        )
        let session = ImportSession()
        let importDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDropImportTests-\(UUID().uuidString)")
        self.saved = saved
        self.session = session
        self.importDirectory = importDirectory
        service = SMBImportService(
            store: store,
            importDirectory: { importDirectory },
            sessionFactory: { _, _ in session }
        )
    }
}

private final class ImportSession: SMBImportSession {
    var timeout: TimeInterval = 0
    var directoryEntries: [String: [[URLResourceKey: Any]]] = [:]
    var downloadPayloads: [String: Data] = [:]
    var failingDownloadPaths: Set<String> = []
    private(set) var connectedShares: [String] = []
    private(set) var requestedDirectoryPaths: [String] = []
    private(set) var requestedDownloadPaths: [String] = []
    private(set) var gracefulDisconnects: [Bool] = []

    func connectShare(name: String, encrypted: Bool) async throws {
        connectedShares.append(name)
    }

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]] {
        requestedDirectoryPaths.append(path)
        return directoryEntries[path] ?? []
    }

    func downloadItem(
        atPath path: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Bool
    ) async throws {
        requestedDownloadPaths.append(path)
        if failingDownloadPaths.contains(path) {
            throw ImportSessionError.downloadFailed
        }
        let payload = downloadPayloads[path] ?? Data()
        try payload.write(to: localURL)
        _ = progress(Int64(payload.count), Int64(payload.count))
    }

    func disconnectShare(gracefully: Bool) async throws {
        gracefulDisconnects.append(gracefully)
    }
}

private enum ImportSessionError: Error {
    case downloadFailed
}

private final class ImportProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SMBImportProgress] = []

    var values: [SMBImportProgress] {
        lock.withLock { storage }
    }

    func record(_ progress: SMBImportProgress) {
        lock.withLock { storage.append(progress) }
    }
}

private final class ImportMemoryPasswordVault: PasswordVault {
    private var password: String?

    func readPassword() throws -> String? {
        password
    }

    func savePassword(_ password: String) throws {
        self.password = password
    }

    func removePassword() throws {
        password = nil
    }
}
