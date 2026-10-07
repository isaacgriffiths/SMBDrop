import Foundation

/// Work a chunked photo export keeps outside the outbox. Large exports copy
/// originals a chunk at a time, and clear finished chunks from the outbox so
/// a whole-library backup never leaves thousands of records behind.
struct ChunkedBatchCounts: Codable, Equatable, Sendable {
    /// Photos promised to the batch but not copied into the outbox yet.
    var unstaged = 0
    /// Finished items already cleared from the outbox.
    var archivedCompleted = 0
    var archivedBytes: Int64 = 0
    /// Photos that could not be copied out of the library at all.
    var failedToStage = 0
}

struct TransferBatchProgress: Equatable, Sendable {
    let totalCount: Int
    let completedCount: Int
    let failedCount: Int
    let currentItemNumber: Int
    let bytesTransferred: Int64
    let totalBytes: Int64
    let currentFilename: String?
    let unstagedCount: Int
    private let itemNumbers: [UUID: Int]

    init(transfers: [Transfer], chunked: ChunkedBatchCounts = ChunkedBatchCounts()) {
        let ordered = transfers.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        let archived = max(0, chunked.archivedCompleted)
        let failedToStage = max(0, chunked.failedToStage)
        unstagedCount = max(0, chunked.unstaged)
        itemNumbers = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map {
                ($0.element.id, archived + $0.offset + 1)
            }
        )
        totalCount = archived + ordered.count + unstagedCount + failedToStage
        completedCount = archived + ordered.filter { $0.status == .completed }.count
        failedCount = failedToStage + ordered.filter { $0.status == .failed }.count
        let activeTransfer = ordered.first(where: { $0.status == .uploading })
            ?? ordered.first(where: { $0.status == .queued })
        // Between staged chunks the next unstaged photo is the current item,
        // not the most recent failure.
        let displayedTransfer = activeTransfer
            ?? (unstagedCount > 0 ? nil : ordered.last(where: { $0.status == .failed }))
        currentFilename = displayedTransfer?.filename

        if let displayedTransfer {
            currentItemNumber = itemNumbers[displayedTransfer.id] ?? 0
        } else if unstagedCount > 0 {
            currentItemNumber = archived + ordered.count + 1
        } else if totalCount > 0, completedCount == totalCount {
            currentItemNumber = totalCount
        } else {
            currentItemNumber = 0
        }

        let archivedBytes = max(0, chunked.archivedBytes)
        totalBytes = archivedBytes + ordered.reduce(0) { $0 + max(0, $1.byteCount) }
        bytesTransferred = archivedBytes + ordered.reduce(0) { partial, transfer in
            switch transfer.status {
            case .completed:
                partial + max(0, transfer.byteCount)
            case .uploading:
                partial + min(max(0, transfer.bytesTransferred), max(0, transfer.byteCount))
            case .queued, .failed:
                partial
            }
        }
    }

    /// Byte-based while every item's size is known; photos still waiting to
    /// be copied have no size yet, so until then it counts items instead.
    var fractionCompleted: Double {
        if unstagedCount == 0, totalBytes > 0 {
            return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
        }
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    var countText: String {
        "\(currentItemNumber) of \(totalCount)"
    }

    func itemNumber(for transferID: UUID) -> Int? {
        itemNumbers[transferID]
    }

    var isComplete: Bool {
        totalCount > 0 && completedCount == totalCount
    }
}
