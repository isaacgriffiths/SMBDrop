import Foundation
import Darwin

struct Transfer: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued
        case uploading
        case failed
        case completed
    }

    let id: UUID
    let filename: String
    let byteCount: Int64
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var bytesTransferred: Int64
    var attemptCount: Int
    var remoteFilename: String?
    var errorMessage: String?
}

struct TransferWork: Sendable {
    let transfer: Transfer
    let fileURL: URL
    let claimID: UUID
}

actor TransferOutbox {
    static let appGroup = SMBDropAppGroup.identifier

    private let rootURL: URL
    private let fileManager: FileManager
    private let claimLeaseDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        claimLeaseDuration: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.claimLeaseDuration = max(1, claimLeaseDuration)
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    static func shared(fileManager: FileManager = .default) throws -> TransferOutbox {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw TransferOutboxError.appGroupUnavailable
        }
        return TransferOutbox(
            rootURL: containerURL.appendingPathComponent("Transfers", isDirectory: true),
            fileManager: fileManager
        )
    }

    func enqueueFile(
        at sourceURL: URL,
        filename: String,
        moveSource: Bool = false
    ) throws -> Transfer {
        let filename = try canonicalFilename(filename)
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true else {
            throw TransferOutboxError.sourceIsNotAFile
        }

        return try withExclusiveLock {
            let currentDate = now()
            let transfer = Transfer(
                id: UUID(),
                filename: filename,
                byteCount: Int64(resourceValues.fileSize ?? 0),
                createdAt: currentDate,
                updatedAt: currentDate,
                status: .queued,
                bytesTransferred: 0,
                attemptCount: 0,
                remoteFilename: nil,
                errorMessage: nil
            )
            let directoryURL = transferDirectoryURL(for: transfer.id)

            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                if moveSource {
                    try fileManager.moveItem(at: sourceURL, to: payloadURL(for: transfer.id))
                } else {
                    try fileManager.copyItem(at: sourceURL, to: payloadURL(for: transfer.id))
                }
                try write(transfer)
                return transfer
            } catch {
                try? fileManager.removeItem(at: directoryURL)
                throw error
            }
        }
    }

    func transfers() throws -> [Transfer] {
        try withExclusiveLock {
            try transfersUnlocked()
        }
    }

    func claimNext() throws -> TransferWork? {
        try withExclusiveLock {
            let currentDate = now()
            let storedTransfers = try transfersUnlocked()

            for transfer in storedTransfers
            where transfer.status == .queued || transfer.status == .uploading {
                if let claim = try readClaim(for: transfer.id), claim.expiresAt > currentDate {
                    return nil
                }
            }

            for storedTransfer in storedTransfers {
                var transfer = storedTransfer
                let existingClaim = try readClaim(for: transfer.id)

                switch transfer.status {
                case .queued:
                    if let existingClaim {
                        guard existingClaim.expiresAt <= currentDate else { continue }
                        try removeClaim(for: transfer.id)
                    }
                case .uploading:
                    guard (existingClaim?.expiresAt ?? .distantPast) <= currentDate else { continue }
                    try removeClaim(for: transfer.id)
                case .failed, .completed:
                    continue
                }

                let fileURL = payloadURL(for: transfer.id)
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    throw TransferOutboxError.payloadMissing
                }

                let claim = Claim(
                    id: UUID(),
                    expiresAt: currentDate.addingTimeInterval(claimLeaseDuration)
                )
                transfer.status = .uploading
                transfer.updatedAt = currentDate
                transfer.bytesTransferred = 0
                transfer.attemptCount += 1
                transfer.errorMessage = nil

                do {
                    try write(transfer)
                    try writeClaim(claim, for: transfer.id)
                    return TransferWork(
                        transfer: transfer,
                        fileURL: fileURL,
                        claimID: claim.id
                    )
                } catch {
                    try? removeClaim(for: transfer.id)
                    try? write(storedTransfer)
                    throw error
                }
            }

            return nil
        }
    }

    func fail(_ work: TransferWork, message: String) throws -> Transfer {
        try withExclusiveLock {
            var transfer = try transferUnlocked(id: work.transfer.id)
            try requireCurrentClaim(work)
            guard transfer.status == .uploading else {
                throw TransferOutboxError.invalidState
            }

            transfer.status = .failed
            transfer.updatedAt = now()
            transfer.errorMessage = message
            try write(transfer)
            try removeClaim(for: transfer.id)
            return transfer
        }
    }

    func updateProgress(_ work: TransferWork, bytesTransferred: Int64) throws -> Transfer {
        try withExclusiveLock {
            var transfer = try transferUnlocked(id: work.transfer.id)
            try requireCurrentClaim(work)
            guard transfer.status == .uploading else {
                throw TransferOutboxError.invalidState
            }
            guard bytesTransferred >= transfer.bytesTransferred,
                  bytesTransferred <= transfer.byteCount else {
                throw TransferOutboxError.invalidProgress
            }

            let currentDate = now()
            let renewedClaim = Claim(
                id: work.claimID,
                expiresAt: currentDate.addingTimeInterval(claimLeaseDuration)
            )
            try writeClaim(renewedClaim, for: transfer.id)

            transfer.updatedAt = currentDate
            transfer.bytesTransferred = bytesTransferred
            try write(transfer)
            return transfer
        }
    }

    func complete(_ work: TransferWork, remoteFilename: String) throws -> Transfer {
        let remoteFilename = try canonicalFilename(remoteFilename)
        return try withExclusiveLock {
            var transfer = try transferUnlocked(id: work.transfer.id)
            try requireCurrentClaim(work)
            guard transfer.status == .uploading else {
                throw TransferOutboxError.invalidState
            }

            transfer.status = .completed
            transfer.updatedAt = now()
            transfer.bytesTransferred = transfer.byteCount
            transfer.remoteFilename = remoteFilename
            transfer.errorMessage = nil
            try write(transfer)

            let fileURL = payloadURL(for: transfer.id)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try removeClaim(for: transfer.id)
            return transfer
        }
    }

    func retry(_ id: UUID) throws -> Transfer {
        try withExclusiveLock {
            var transfer = try transferUnlocked(id: id)
            guard transfer.status == .failed else {
                throw TransferOutboxError.invalidState
            }
            guard fileManager.fileExists(atPath: payloadURL(for: id).path) else {
                throw TransferOutboxError.payloadMissing
            }

            transfer.status = .queued
            transfer.updatedAt = now()
            transfer.bytesTransferred = 0
            transfer.remoteFilename = nil
            transfer.errorMessage = nil
            try removeClaim(for: id)
            try write(transfer)
            return transfer
        }
    }

    func remove(_ id: UUID) throws {
        try withExclusiveLock {
            _ = try transferUnlocked(id: id)
            try fileManager.removeItem(at: transferDirectoryURL(for: id))
        }
    }

    private func transfersUnlocked() throws -> [Transfer] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let transfers = directoryURLs.compactMap { directoryURL -> Transfer? in
            guard let transfer = try? decoder.decode(
                Transfer.self,
                from: Data(contentsOf: directoryURL.appendingPathComponent("transfer.json"))
            ) else {
                return nil
            }

            if transfer.status == .completed {
                let stagedPayloadURL = payloadURL(for: transfer.id)
                if fileManager.fileExists(atPath: stagedPayloadURL.path) {
                    try? fileManager.removeItem(at: stagedPayloadURL)
                }
            }
            return transfer
        }

        return transfers.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private func transferUnlocked(id: UUID) throws -> Transfer {
        guard let transfer = try transfersUnlocked().first(where: { $0.id == id }) else {
            throw TransferOutboxError.transferNotFound
        }
        return transfer
    }

    private func canonicalFilename(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              URL(fileURLWithPath: value).lastPathComponent == value else {
            throw TransferOutboxError.invalidFilename
        }
        return value
    }

    private func transferDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func payloadURL(for id: UUID) -> URL {
        transferDirectoryURL(for: id).appendingPathComponent("payload", isDirectory: false)
    }

    private func claimURL(for id: UUID) -> URL {
        transferDirectoryURL(for: id).appendingPathComponent("claim.json", isDirectory: false)
    }

    private func write(_ transfer: Transfer) throws {
        let data = try encoder.encode(transfer)
        try data.write(
            to: transferDirectoryURL(for: transfer.id).appendingPathComponent("transfer.json"),
            options: .atomic
        )
    }

    private func readClaim(for id: UUID) throws -> Claim? {
        let url = claimURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Claim.self, from: Data(contentsOf: url))
    }

    private func writeClaim(_ claim: Claim, for id: UUID) throws {
        try encoder.encode(claim).write(to: claimURL(for: id), options: .atomic)
    }

    private func removeClaim(for id: UUID) throws {
        let url = claimURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func requireCurrentClaim(_ work: TransferWork) throws {
        guard let claim = try readClaim(for: work.transfer.id),
              claim.id == work.claimID else {
            throw TransferOutboxError.claimNoLongerValid
        }
    }

    private func withExclusiveLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let lockURL = rootURL.appendingPathComponent(".outbox.lock", isDirectory: false)
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_EXLOCK, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw TransferOutboxError.storageLockUnavailable
        }
        defer { Darwin.close(descriptor) }

        return try operation()
    }

    private struct Claim: Codable {
        let id: UUID
        let expiresAt: Date
    }
}

enum TransferOutboxError: LocalizedError {
    case appGroupUnavailable
    case invalidFilename
    case invalidProgress
    case invalidState
    case payloadMissing
    case sourceIsNotAFile
    case storageLockUnavailable
    case claimNoLongerValid
    case transferNotFound

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "SMBDrop could not open its shared transfer storage."
        case .invalidFilename:
            "That file does not have a valid name."
        case .invalidProgress:
            "The transfer progress is outside the staged file size."
        case .invalidState:
            "That transfer cannot be changed from its current state."
        case .payloadMissing:
            "The staged file is missing. Add it to the queue again."
        case .sourceIsNotAFile:
            "Only files can be added to the transfer queue."
        case .storageLockUnavailable:
            "SMBDrop could not safely update its shared transfer queue."
        case .claimNoLongerValid:
            "Another SMBDrop process has taken over this transfer."
        case .transferNotFound:
            "That transfer is no longer in the queue."
        }
    }
}
