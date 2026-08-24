import SwiftUI

struct TransferActivityView: View {
    @ObservedObject var transferQueue: TransferQueueViewModel

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
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }
}
