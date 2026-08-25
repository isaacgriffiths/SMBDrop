import SwiftUI

struct TransferHistoryView: View {
    @ObservedObject var transferQueue: TransferQueueViewModel
    @State private var isConfirmingClear = false

    private var completedTransfers: [Transfer] {
        transferQueue.transfers.filter { $0.status == .completed }
    }

    var body: some View {
        List {
            if transferQueue.activeProgress != nil {
                Section("Current Transfer") {
                    TransferActivityView(transferQueue: transferQueue)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if transferQueue.transfers.isEmpty {
                ContentUnavailableView(
                    "No Transfers Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Uploads from Photos and Files will appear here.")
                )
            } else {
                Section("History") {
                    ForEach(transferQueue.transfers.reversed()) { transfer in
                        transferRow(transfer)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if transfer.status != .uploading {
                                    Button("Remove", role: .destructive) {
                                        Task { await transferQueue.remove(transfer.id) }
                                    }
                                }
                                if transfer.status == .failed {
                                    Button("Retry") {
                                        Task { await transferQueue.retry(transfer.id) }
                                    }
                                    .tint(.blue)
                                }
                            }
                            .contextMenu {
                                if transfer.status == .failed {
                                    Button {
                                        Task { await transferQueue.retry(transfer.id) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                    }
                                }
                                if transfer.status != .uploading {
                                    Button(role: .destructive) {
                                        Task { await transferQueue.remove(transfer.id) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Transfer History")
        .toolbar {
            if !completedTransfers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear Completed", role: .destructive) {
                            isConfirmingClear = true
                        }
                    } label: {
                        Label("History Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear completed transfers?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Completed", role: .destructive) {
                let ids = completedTransfers.map(\.id)
                Task {
                    for id in ids {
                        await transferQueue.remove(id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes history. Files already uploaded to your SMB shares are not affected.")
        }
        .task { await transferQueue.refresh() }
    }

    private func transferRow(_ transfer: Transfer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: transfer.status))
                .font(.title3)
                .foregroundStyle(color(for: transfer.status))
                .frame(width: 30, height: 30)
                .background(
                    color(for: transfer.status).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(transfer.remoteFilename ?? transfer.filename)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(status(for: transfer.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: transfer.status))
                }
                if let destination = transferQueue.destinationName(for: transfer) {
                    Text(destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: transfer.byteCount, countStyle: .file)) · "
                        + transfer.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let error = transfer.errorMessage, transfer.status == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func icon(for status: Transfer.Status) -> String {
        switch status {
        case .queued: "clock.fill"
        case .uploading: "arrow.up.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func color(for status: Transfer.Status) -> Color {
        switch status {
        case .queued: .secondary
        case .uploading: .blue
        case .failed: .red
        case .completed: .green
        }
    }

    private func status(for status: Transfer.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .uploading: "Sending"
        case .failed: "Failed"
        case .completed: "Uploaded"
        }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 76, height: 76)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    Text("SMBDrop")
                        .font(.title2.bold())
                    Text("Move photos, videos, and files between this iPhone and your SMB shares without an account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section("Privacy") {
                Label("Passwords stay in this iPhone’s Keychain", systemImage: "key.fill")
                Label("Transfers go directly to your SMB server", systemImage: "arrow.left.arrow.right")
                Label("No SMBDrop account is required", systemImage: "person.crop.circle.badge.checkmark")
            }

            Section("App Information") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
                NavigationLink("Third-Party Notices") {
                    ThirdPartyNoticesView()
                }
            }
        }
        .navigationTitle("About")
    }
}

private struct ThirdPartyNoticesView: View {
    private var notices: String {
        guard let url = Bundle.main.url(
            forResource: "ThirdPartyNotices",
            withExtension: "txt"
        ) else {
            return "Third-party notices are unavailable."
        }
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? "Third-party notices are unavailable."
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Third-Party Notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}
