import AMSMB2
import Foundation

struct SMBRemoteItem: Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let byteCount: Int64?
    let modificationDate: Date?

    var id: String { relativePath }
}

struct SMBImportProgress: Equatable, Sendable {
    let filename: String
    let completedItemCount: Int
    let totalItemCount: Int
    let bytesTransferred: Int64
    let totalBytes: Int64?
}

protocol SMBImportServing {
    func contents(
        of destinationID: UUID,
        at relativePath: String
    ) async throws -> [SMBRemoteItem]
    func importItems(
        _ items: [SMBRemoteItem],
        from destinationID: UUID,
        progress: @escaping @Sendable (SMBImportProgress) -> Void
    ) async throws -> [URL]
}

protocol SMBImportSession: AnyObject {
    var timeout: TimeInterval { get set }
    func connectShare(name: String, encrypted: Bool) async throws
    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]]
    func downloadItem(
        atPath path: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Bool
    ) async throws
    func disconnectShare(gracefully: Bool) async throws
}

struct SMBImportService {
    typealias SessionFactory = (Destination, String) -> (any SMBImportSession)?

    private let store: DestinationStore
    private let importDirectory: () throws -> URL
    private let sessionFactory: SessionFactory

    init(
        store: DestinationStore = DestinationStore(),
        importDirectory: @escaping () throws -> URL = Self.defaultImportDirectory,
        sessionFactory: @escaping SessionFactory = Self.makeSession
    ) {
        self.store = store
        self.importDirectory = importDirectory
        self.sessionFactory = sessionFactory
    }

    func contents(
        of destinationID: UUID,
        at relativePath: String
    ) async throws -> [SMBRemoteItem] {
        let saved = try savedDestination(id: destinationID)
        guard let session = sessionFactory(saved.destination, saved.password) else {
            throw SMBConnectionError.invalidServer
        }
        session.timeout = 30

        do {
            try await connect(session, share: saved.destination.share)
            let relativePath = try Self.validatedRelativePath(relativePath)
            let entries = try await session.contentsOfDirectory(
                atPath: Self.remotePath(
                    destination: saved.destination,
                    relativePath: relativePath
                )
            )
            let items = try entries.compactMap { attributes -> SMBRemoteItem? in
                guard let name = attributes[.nameKey] as? String,
                      name != ".",
                      name != ".." else {
                    return nil
                }
                try Self.validateFilename(name)
                let itemPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                return SMBRemoteItem(
                    name: name,
                    relativePath: itemPath,
                    isDirectory: attributes[.isDirectoryKey] as? Bool == true,
                    byteCount: Self.fileSize(in: attributes),
                    modificationDate: attributes[.contentModificationDateKey] as? Date
                )
            }
            try? await session.disconnectShare(gracefully: true)
            return items.sorted(by: Self.sortItems)
        } catch {
            try? await session.disconnectShare(gracefully: false)
            if error is SMBImportError {
                throw error
            }
            throw SMBConnectionError.friendly(error)
        }
    }

    func importItems(
        _ items: [SMBRemoteItem],
        from destinationID: UUID,
        progress: @escaping @Sendable (SMBImportProgress) -> Void
    ) async throws -> [URL] {
        guard !items.isEmpty else { return [] }
        guard items.allSatisfy({ !$0.isDirectory }) else {
            throw SMBImportError.cannotImportFolder
        }
        let saved = try savedDestination(id: destinationID)
        guard let session = sessionFactory(saved.destination, saved.password) else {
            throw SMBConnectionError.invalidServer
        }
        session.timeout = 30
        let directory = try importDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var imported: [URL] = []
        var partialURL: URL?

        do {
            try await connect(session, share: saved.destination.share)
            for (index, item) in items.enumerated() {
                try Self.validateFilename(item.name)
                let relativePath = try Self.validatedRelativePath(item.relativePath)
                guard let expectedSize = item.byteCount else {
                    throw SMBImportError.sizeUnavailable
                }
                let localURL = directory.appendingPathComponent(item.name, isDirectory: false)
                let existingNames = try FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
                guard !existingNames.contains(where: {
                    $0.caseInsensitiveCompare(item.name) == .orderedSame
                }) else {
                    throw SMBImportError.fileAlreadyExists(item.name)
                }
                let temporaryURL = directory.appendingPathComponent(
                    "smbdrop-\(UUID().uuidString).partial",
                    isDirectory: false
                )
                partialURL = temporaryURL
                let remotePath = Self.remotePath(
                    destination: saved.destination,
                    relativePath: relativePath
                )
                try await session.downloadItem(
                    atPath: remotePath,
                    to: temporaryURL
                ) { bytes, _ in
                    progress(
                        SMBImportProgress(
                            filename: item.name,
                            completedItemCount: index,
                            totalItemCount: items.count,
                            bytesTransferred: max(0, bytes),
                            totalBytes: expectedSize
                        )
                    )
                    return !Task.isCancelled
                }
                guard !Task.isCancelled else { throw CancellationError() }
                let actualSize = try Self.localFileSize(at: temporaryURL)
                guard actualSize == expectedSize else {
                    throw SMBImportError.sizeMismatch(item.name)
                }
                if let modificationDate = item.modificationDate {
                    try FileManager.default.setAttributes(
                        [.modificationDate: modificationDate],
                        ofItemAtPath: temporaryURL.path
                    )
                }
                try FileManager.default.moveItem(at: temporaryURL, to: localURL)
                partialURL = nil
                imported.append(localURL)
                progress(
                    SMBImportProgress(
                        filename: item.name,
                        completedItemCount: index + 1,
                        totalItemCount: items.count,
                        bytesTransferred: expectedSize,
                        totalBytes: expectedSize
                    )
                )
            }
            try? await session.disconnectShare(gracefully: true)
            return imported
        } catch {
            if let partialURL {
                try? FileManager.default.removeItem(at: partialURL)
            }
            try? await session.disconnectShare(gracefully: false)
            let reportedError: any Error
            if error is SMBImportError || error is CancellationError {
                reportedError = error
            } else {
                reportedError = SMBConnectionError.friendly(error)
            }
            if !imported.isEmpty {
                throw SMBImportPartialFailure(
                    importedItems: Array(items.prefix(imported.count)),
                    importedURLs: imported,
                    totalItemCount: items.count,
                    failureDescription: reportedError.localizedDescription
                )
            }
            throw reportedError
        }
    }

    private func savedDestination(id: UUID) throws -> SavedDestination {
        guard let destination = try store.loadAll().first(where: { $0.id == id }) else {
            throw SMBImportError.destinationUnavailable
        }
        return destination
    }

    private func connect(_ session: any SMBImportSession, share: String) async throws {
        do {
            try await session.connectShare(name: share, encrypted: false)
        } catch {
            let friendly = SMBConnectionError.friendly(error)
            guard friendly == .authenticationFailed || friendly == .connectionFailed else {
                throw error
            }
            try await session.connectShare(name: share, encrypted: true)
        }
    }

    private static func validatedRelativePath(_ path: String) throws -> String {
        let trimmed = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.contains("\\") else {
            throw SMBImportError.invalidRemotePath
        }
        if trimmed.isEmpty { return "" }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SMBImportError.invalidRemotePath
        }
        return trimmed
    }

    private static func validateFilename(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0") else {
            throw SMBImportError.invalidRemotePath
        }
    }

    private static func remotePath(
        destination: Destination,
        relativePath: String
    ) -> String {
        let components = [destination.subfolder, relativePath].filter { !$0.isEmpty }
        return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))"
    }

    private static func fileSize(in attributes: [URLResourceKey: Any]) -> Int64? {
        if let number = attributes[.fileSizeKey] as? NSNumber {
            return number.int64Value
        }
        if let value = attributes[.fileSizeKey] as? Int64 {
            return value
        }
        if let value = attributes[.fileSizeKey] as? Int {
            return Int64(value)
        }
        return nil
    }

    private static func localFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes[.size] as? NSNumber {
            return number.int64Value
        }
        if let value = attributes[.size] as? Int64 {
            return value
        }
        if let value = attributes[.size] as? Int {
            return Int64(value)
        }
        throw SMBImportError.sizeUnavailable
    }

    private static func sortItems(_ lhs: SMBRemoteItem, _ rhs: SMBRemoteItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func defaultImportDirectory() throws -> URL {
        try defaultImportDirectory(fileManager: .default)
    }

    static func defaultImportDirectory(fileManager: FileManager) throws -> URL {
        guard let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw SMBImportError.importDirectoryUnavailable
        }
        return documents.appendingPathComponent("SMBDrop Imports", isDirectory: true)
    }

    private static func makeSession(
        destination: Destination,
        password: String
    ) -> (any SMBImportSession)? {
        let credential = URLCredential(
            user: destination.username,
            password: password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: destination.serverURL, credential: credential) else {
            return nil
        }
        return AMSMB2ImportSession(manager: manager)
    }
}

extension SMBImportService: SMBImportServing {}

struct SMBImportPartialFailure: LocalizedError, Sendable {
    let importedItems: [SMBRemoteItem]
    let importedURLs: [URL]
    let totalItemCount: Int
    let failureDescription: String

    var errorDescription: String? {
        "Imported \(importedItems.count) of \(totalItemCount) items. \(failureDescription)"
    }
}

enum SMBImportError: LocalizedError, Equatable {
    case destinationUnavailable
    case importDirectoryUnavailable
    case invalidRemotePath
    case cannotImportFolder
    case fileAlreadyExists(String)
    case sizeMismatch(String)
    case sizeUnavailable

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "That SMB share is no longer saved."
        case .importDirectoryUnavailable:
            "SMBDrop could not open its Imports folder on this iPhone."
        case .invalidRemotePath:
            "The SMB server returned an unsafe file path, so SMBDrop did not import it."
        case .cannotImportFolder:
            "Open the folder and select the files you want to import."
        case .fileAlreadyExists(let filename):
            "A file named \(filename) already exists in SMBDrop Imports. Move or rename it in Files, then try again."
        case .sizeMismatch(let filename):
            "\(filename) did not download completely, so SMBDrop removed the partial file."
        case .sizeUnavailable:
            "SMBDrop could not verify the downloaded file size."
        }
    }
}

private final class AMSMB2ImportSession: SMBImportSession {
    private let manager: SMB2Manager

    init(manager: SMB2Manager) {
        self.manager = manager
    }

    var timeout: TimeInterval {
        get { manager.timeout }
        set { manager.timeout = newValue }
    }

    func connectShare(name: String, encrypted: Bool) async throws {
        try await manager.connectShare(name: name, encrypted: encrypted)
    }

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]] {
        try await manager.contentsOfDirectory(atPath: path)
    }

    func downloadItem(
        atPath path: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Bool
    ) async throws {
        try await manager.downloadItem(atPath: path, to: localURL, progress: progress)
    }

    func disconnectShare(gracefully: Bool) async throws {
        try await manager.disconnectShare(gracefully: gracefully)
    }
}
