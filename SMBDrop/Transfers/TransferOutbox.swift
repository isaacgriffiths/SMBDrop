import Foundation

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
}

actor TransferOutbox {
    static let appGroup = DestinationStore.appGroup

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
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

    func enqueueFile(at sourceURL: URL, filename: String) throws -> Transfer {
        let filename = try canonicalFilename(filename)
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true else {
            throw TransferOutboxError.sourceIsNotAFile
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let now = Date()
        let transfer = Transfer(
            id: UUID(),
            filename: filename,
            byteCount: Int64(resourceValues.fileSize ?? 0),
            createdAt: now,
            updatedAt: now,
            status: .queued,
            bytesTransferred: 0,
            attemptCount: 0,
            remoteFilename: nil,
            errorMessage: nil
        )
        let directoryURL = transferDirectoryURL(for: transfer.id)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try fileManager.copyItem(at: sourceURL, to: payloadURL(for: transfer.id))
            try write(transfer)
            return transfer
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func transfers() throws -> [Transfer] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { directoryURL in
            try? decoder.decode(
                Transfer.self,
                from: Data(contentsOf: directoryURL.appendingPathComponent("transfer.json"))
            )
        }
        .sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func claimNext() throws -> TransferWork? {
        guard var transfer = try transfers().first(where: { $0.status == .queued }) else {
            return nil
        }
        let fileURL = payloadURL(for: transfer.id)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw TransferOutboxError.payloadMissing
        }

        transfer.status = .uploading
        transfer.updatedAt = Date()
        transfer.attemptCount += 1
        transfer.errorMessage = nil
        try write(transfer)
        return TransferWork(transfer: transfer, fileURL: fileURL)
    }

    private func canonicalFilename(_ value: String) throws -> String {
        let filename = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw TransferOutboxError.invalidFilename
        }
        return filename
    }

    private func transferDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func payloadURL(for id: UUID) -> URL {
        transferDirectoryURL(for: id).appendingPathComponent("payload", isDirectory: false)
    }

    private func write(_ transfer: Transfer) throws {
        let data = try encoder.encode(transfer)
        try data.write(
            to: transferDirectoryURL(for: transfer.id).appendingPathComponent("transfer.json"),
            options: .atomic
        )
    }
}

enum TransferOutboxError: LocalizedError {
    case appGroupUnavailable
    case invalidFilename
    case payloadMissing
    case sourceIsNotAFile

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "SMBDrop could not open its shared transfer storage."
        case .invalidFilename:
            "That file does not have a valid name."
        case .payloadMissing:
            "The staged file is missing. Add it to the queue again."
        case .sourceIsNotAFile:
            "Only files can be added to the transfer queue."
        }
    }
}
