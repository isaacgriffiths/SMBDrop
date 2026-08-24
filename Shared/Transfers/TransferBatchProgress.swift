import Foundation

struct TransferBatchProgress: Equatable, Sendable {
    let totalCount: Int
    let completedCount: Int
    let failedCount: Int
    let currentItemNumber: Int
    let bytesTransferred: Int64
    let totalBytes: Int64
    let currentFilename: String?

    init(transfers: [Transfer]) {
        let ordered = transfers.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        totalCount = ordered.count
        completedCount = ordered.filter { $0.status == .completed }.count
        failedCount = ordered.filter { $0.status == .failed }.count
        currentFilename = ordered.first(where: { $0.status == .uploading })?.filename
            ?? ordered.first(where: { $0.status == .queued })?.filename
            ?? ordered.first(where: { $0.status == .failed })?.filename

        if ordered.isEmpty {
            currentItemNumber = 0
        } else if completedCount == ordered.count {
            currentItemNumber = ordered.count
        } else {
            currentItemNumber = min(ordered.count, completedCount + 1)
        }

        totalBytes = ordered.reduce(0) { $0 + max(0, $1.byteCount) }
        bytesTransferred = ordered.reduce(0) { partial, transfer in
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

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
        }
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    var countText: String {
        "\(currentItemNumber) of \(totalCount)"
    }

    var isComplete: Bool {
        totalCount > 0 && completedCount == totalCount
    }
}
