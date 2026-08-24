import AMSMB2
import Foundation

protocol SMBUploadSession: AnyObject {
    var timeout: TimeInterval { get set }
    func connectShare(name: String, encrypted: Bool) async throws
    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]]
    func uploadItem(
        at localURL: URL,
        toPath remotePath: String,
        progress: @escaping @Sendable (Int64) -> Bool
    ) async throws
    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any]
    func setAttributes(
        _ attributes: [URLResourceKey: Any],
        ofItemAtPath path: String
    ) async throws
    func moveItem(atPath path: String, toPath: String) async throws
    func removeFile(atPath path: String) async throws
    func disconnectShare(gracefully: Bool) async throws
}

protocol SMBTransferUploading {
    func upload(
        _ work: TransferWork,
        to destination: Destination,
        password: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String
}

struct SMBTransferUploader: SMBTransferUploading {
    typealias SessionFactory = (Destination, String) -> (any SMBUploadSession)?

    private let sessionFactory: SessionFactory
    private let makeUUID: () -> UUID

    init(
        sessionFactory: @escaping SessionFactory = Self.makeSession,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.sessionFactory = sessionFactory
        self.makeUUID = makeUUID
    }

    func upload(
        _ work: TransferWork,
        to destination: Destination,
        password: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        guard let session = sessionFactory(destination, password) else {
            throw SMBConnectionError.invalidServer
        }
        session.timeout = 30
        var partialPath: String?

        do {
            try await connect(session, share: destination.share)
            let entries = try await session.contentsOfDirectory(atPath: destination.remotePath)
            let existingNames = Set(entries.compactMap { $0[.nameKey] as? String })
            let remoteFilename = work.transfer.filename
            guard !existingNames.contains(where: {
                $0.caseInsensitiveCompare(remoteFilename) == .orderedSame
            }) else {
                throw TransferUploadError.fileAlreadyExists(remoteFilename)
            }
            let finalPath = Self.remotePath(
                folderPath: destination.remotePath,
                filename: remoteFilename
            )
            let temporaryPath = Self.remotePath(
                folderPath: destination.remotePath,
                filename: ".\(makeUUID().uuidString).smbdrop-partial"
            )
            partialPath = temporaryPath

            try await session.uploadItem(at: work.fileURL, toPath: temporaryPath) { bytes in
                progress(bytes)
                return true
            }
            let attributes = try await session.attributesOfItem(atPath: temporaryPath)
            guard Self.fileSize(in: attributes) == work.transfer.byteCount else {
                throw TransferUploadError.sizeMismatch
            }
            var sourceDates: [URLResourceKey: Any] = [:]
            if let creationDate = work.transfer.sourceCreationDate {
                sourceDates[.creationDateKey] = creationDate
            }
            guard let modificationDate = work.transfer.sourceModificationDate else {
                throw TransferUploadError.sourceTimestampUnavailable
            }
            sourceDates[.contentModificationDateKey] = modificationDate
            try await session.setAttributes(sourceDates, ofItemAtPath: temporaryPath)
            try await session.moveItem(atPath: temporaryPath, toPath: finalPath)
            partialPath = nil
            try? await session.disconnectShare(gracefully: true)
            return remoteFilename
        } catch {
            if let partialPath {
                try? await session.removeFile(atPath: partialPath)
            }
            try? await session.disconnectShare(gracefully: false)
            if error is TransferUploadError {
                throw error
            }
            throw SMBConnectionError.friendly(error)
        }
    }

    static func remotePath(folderPath: String, filename: String) -> String {
        let folder = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? "/\(filename)" : "/\(folder)/\(filename)"
    }

    private static func fileSize(in attributes: [URLResourceKey: Any]) -> Int64? {
        if let value = attributes[.fileSizeKey] as? NSNumber {
            return value.int64Value
        }
        if let value = attributes[.fileSizeKey] as? Int64 {
            return value
        }
        if let value = attributes[.fileSizeKey] as? Int {
            return Int64(value)
        }
        return nil
    }

    private func connect(_ session: any SMBUploadSession, share: String) async throws {
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

    private static func makeSession(
        destination: Destination,
        password: String
    ) -> (any SMBUploadSession)? {
        let credential = URLCredential(
            user: destination.username,
            password: password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: destination.serverURL, credential: credential) else {
            return nil
        }
        return AMSMB2UploadSession(manager: manager)
    }
}

struct TransferDrainResult: Sendable {
    let completed: [Transfer]
    let failed: Transfer?
}

struct SMBTransferWorker {
    private let uploader: any SMBTransferUploading

    init(uploader: any SMBTransferUploading = SMBTransferUploader()) {
        self.uploader = uploader
    }

    func drain(
        outbox: TransferOutbox,
        destination: Destination,
        password: String,
        destinationID: UUID,
        transferIDs: Set<UUID>? = nil,
        progress: (@Sendable (Transfer) -> Void)? = nil
    ) async -> TransferDrainResult {
        var completed: [Transfer] = []

        do {
            while let work = try await outbox.claimNext(
                for: destinationID,
                matching: transferIDs
            ) {
                let (stream, continuation) = AsyncStream<Int64>.makeStream()
                let progressTask = Task {
                    for await bytes in stream {
                        let boundedBytes = min(max(0, bytes), work.transfer.byteCount)
                        if let updated = try? await outbox.updateProgress(
                            work,
                            bytesTransferred: boundedBytes
                        ) {
                            progress?(updated)
                        }
                    }
                }

                do {
                    let remoteFilename = try await uploader.upload(
                        work,
                        to: destination,
                        password: password
                    ) { bytes in
                        continuation.yield(bytes)
                    }
                    continuation.finish()
                    await progressTask.value
                    let transfer = try await outbox.complete(
                        work,
                        remoteFilename: remoteFilename
                    )
                    progress?(transfer)
                    completed.append(transfer)
                } catch {
                    continuation.finish()
                    await progressTask.value
                    let message = error.localizedDescription
                    let failed = try await outbox.fail(work, message: message)
                    progress?(failed)
                    return TransferDrainResult(completed: completed, failed: failed)
                }
            }
        } catch {
            return TransferDrainResult(completed: completed, failed: nil)
        }

        return TransferDrainResult(completed: completed, failed: nil)
    }
}

enum TransferUploadError: LocalizedError, Equatable {
    case sizeMismatch
    case fileAlreadyExists(String)
    case sourceTimestampUnavailable

    var errorDescription: String? {
        switch self {
        case .sizeMismatch:
            "The server received a different file size, so SMBDrop kept the item queued instead of publishing a damaged file."
        case .fileAlreadyExists(let filename):
            "A file named \(filename) already exists. SMBDrop kept the item queued instead of changing its name or overwriting it."
        case .sourceTimestampUnavailable:
            "The original file timestamp is unavailable. SMBDrop kept the item queued instead of replacing it with the upload time."
        }
    }
}

private final class AMSMB2UploadSession: SMBUploadSession {
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

    func uploadItem(
        at localURL: URL,
        toPath remotePath: String,
        progress: @escaping @Sendable (Int64) -> Bool
    ) async throws {
        try await manager.uploadItem(at: localURL, toPath: remotePath, progress: progress)
    }

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        try await manager.attributesOfItem(atPath: path)
    }

    func setAttributes(
        _ attributes: [URLResourceKey: Any],
        ofItemAtPath path: String
    ) async throws {
        try await manager.setAttributes(attributes: attributes, ofItemAtPath: path)
    }

    func moveItem(atPath path: String, toPath: String) async throws {
        try await manager.moveItem(atPath: path, toPath: toPath)
    }

    func removeFile(atPath path: String) async throws {
        try await manager.removeFile(atPath: path)
    }

    func disconnectShare(gracefully: Bool) async throws {
        try await manager.disconnectShare(gracefully: gracefully)
    }
}
