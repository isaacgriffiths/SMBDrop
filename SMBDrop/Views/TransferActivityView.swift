import SwiftUI

struct TransferActivityView: View {
    @ObservedObject var transferQueue: TransferQueueViewModel
    @State private var showsItems = false

    private var removableTransfers: [Transfer] {
        transferQueue.activeTransfers.filter { $0.status != .completed }
    }

    var body: some View {
        if let progress = transferQueue.activeProgress {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        progress.isComplete ? "Transfer Complete" : "Sending",
                        systemImage: progress.isComplete
                            ? "checkmark.circle.fill"
                            : "arrow.up.circle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(progress.isComplete ? .green : .primary)
                    Spacer()
                    Text(progress.countText)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    if progress.isComplete {
                        Button {
                            transferQueue.dismissProgress()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss completed transfer")
                    }
                }

                ProgressView(value: progress.fractionCompleted)
                    .tint(progress.failedCount > 0 ? .red : .accentColor)

                HStack {
                    if let filename = progress.currentFilename, !progress.isComplete {
                        Text(filename)
                            .lineLimit(1)
                    } else {
                        Text("\(progress.completedCount) of \(progress.totalCount) uploaded")
                    }
                    Spacer()
                    Text("\(Int(progress.fractionCompleted * 100))% total")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let message = transferQueue.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !removableTransfers.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showsItems) {
                        VStack(spacing: 0) {
                            ForEach(removableTransfers) { transfer in
                                HStack(spacing: 10) {
                                    Image(systemName: transfer.status == .uploading
                                        ? "arrow.up.circle.fill"
                                        : "clock"
                                    )
                                    .foregroundStyle(transfer.status == .uploading
                                        ? Color.accentColor
                                        : Color.secondary
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(transfer.filename)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Text(statusText(for: transfer))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if transferQueue.pendingRemovalIDs.contains(transfer.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("Removing \(transfer.filename)")
                                    } else {
                                        Button(role: .destructive) {
                                            Task { await transferQueue.remove(transfer.id) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(transfer.filename) from current transfer")
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    } label: {
                        Text("Manage \(removableTransfers.count) Item\(removableTransfers.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func statusText(for transfer: Transfer) -> String {
        if transferQueue.pendingRemovalIDs.contains(transfer.id) {
            return "Removing…"
        }
        switch transfer.status {
        case .queued: return "Queued"
        case .uploading: return "Sending"
        case .failed: return "Failed"
        case .completed: return "Uploaded"
        }
    }
}
