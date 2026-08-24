import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DestinationSetupViewModel
    @ObservedObject var transferQueue: TransferQueueViewModel
    @State private var destinationToRemove: DestinationSummary?
    @State private var blockedDestinationRemoval: DestinationSummary?
    @State private var destinationRemovalError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.destinations.isEmpty {
                        ContentUnavailableView(
                            "No SMB Shares",
                            systemImage: "externaldrive.badge.plus",
                            description: Text("Add the network folders you want to send photos and files to.")
                        )
                    } else {
                        ForEach(viewModel.destinations) { destination in
                            Button {
                                viewModel.beginEditing(destination)
                            } label: {
                                destinationRow(destination)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    requestRemoval(of: destination)
                                }
                                Button("Edit") {
                                    viewModel.beginEditing(destination)
                                }
                                .tint(.blue)
                            }
                        }
                    }

                    Button {
                        viewModel.beginAdding()
                    } label: {
                        Label("Add SMB Share", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("SMB Shares")
                } footer: {
                    Text("You will choose one of these shares each time you export.")
                }

                if transferQueue.activeProgress != nil {
                    Section("Current Transfer") {
                        TransferActivityView(transferQueue: transferQueue)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if !transferQueue.transfers.isEmpty {
                    Section("Transfer History") {
                        ForEach(transferQueue.transfers.reversed()) { transfer in
                            transferRow(transfer)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "SMBDrop")
                    Label("Passwords stay in this iPhone's Keychain.", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.beginAdding()
                    } label: {
                        Label("Add SMB Share", systemImage: "plus")
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { viewModel.isEditing },
                    set: { isPresented in
                        if !isPresented { viewModel.cancelEditing() }
                    }
                )
            ) {
                DestinationEditorView(viewModel: viewModel)
            }
            .alert(
                "Remove SMB Share?",
                isPresented: Binding(
                    get: { destinationToRemove != nil },
                    set: { if !$0 { destinationToRemove = nil } }
                ),
                presenting: destinationToRemove
            ) { destination in
                Button("Remove", role: .destructive) {
                    Task {
                        let result = await viewModel.removeDestination(destination.id)
                        destinationToRemove = nil
                        switch result {
                        case .removed:
                            break
                        case .pendingTransfers:
                            blockedDestinationRemoval = destination
                        case .failed(let message):
                            destinationRemovalError = message
                        }
                        await transferQueue.refresh()
                    }
                }
                Button("Cancel", role: .cancel) {
                    destinationToRemove = nil
                }
            } message: { destination in
                Text("This removes \(destination.displayName) and its password from this iPhone. Existing history is kept.")
            }
            .alert(
                "Share Has Pending Transfers",
                isPresented: Binding(
                    get: { blockedDestinationRemoval != nil },
                    set: { if !$0 { blockedDestinationRemoval = nil } }
                ),
                presenting: blockedDestinationRemoval
            ) { _ in
                Button("OK", role: .cancel) { blockedDestinationRemoval = nil }
            } message: { destination in
                Text("Finish, retry, or remove the pending items for \(destination.displayName) before deleting this share.")
            }
            .alert(
                "Could Not Remove SMB Share",
                isPresented: Binding(
                    get: { destinationRemovalError != nil },
                    set: { if !$0 { destinationRemovalError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { destinationRemovalError = nil }
            } message: {
                Text(destinationRemovalError ?? "Unknown error")
            }
            .onChange(of: viewModel.destinations) {
                Task { await transferQueue.resume() }
            }
            .task {
                await transferQueue.refresh()
            }
        }
    }

    private func destinationRow(_ destination: DestinationSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(destination.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(destination.destination.username)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func transferRow(_ transfer: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transferIcon(transfer.status))
                    .foregroundStyle(transferColor(transfer.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.remoteFilename ?? transfer.filename)
                        .lineLimit(1)
                    if let destination = transferQueue.destinationName(for: transfer) {
                        Text(destination)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(transferStatus(transfer.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = transfer.errorMessage, transfer.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await transferQueue.retry(transfer.id) }
                }
                Button("Remove from Queue", role: .destructive) {
                    Task { await transferQueue.remove(transfer.id) }
                }
            } else if transfer.status == .completed {
                Button("Remove from History", role: .destructive) {
                    Task { await transferQueue.remove(transfer.id) }
                }
                .font(.caption)
            } else if transfer.status == .queued,
                      transfer.destinationID.flatMap({ transferQueue.destinationNames[$0] }) == nil {
                Button("Remove Unavailable Item", role: .destructive) {
                    Task { await transferQueue.remove(transfer.id) }
                }
                .font(.caption)
            }
        }
    }

    private func transferIcon(_ status: Transfer.Status) -> String {
        switch status {
        case .queued: "clock"
        case .uploading: "arrow.up.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func transferColor(_ status: Transfer.Status) -> Color {
        switch status {
        case .queued: .secondary
        case .uploading: .accentColor
        case .failed: .red
        case .completed: .green
        }
    }

    private func transferStatus(_ status: Transfer.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .uploading: "Sending"
        case .failed: "Failed"
        case .completed: "Uploaded"
        }
    }

    private func requestRemoval(of destination: DestinationSummary) {
        let hasPendingTransfers = transferQueue.transfers.contains {
            $0.destinationID == destination.id && $0.status != .completed
        }
        if hasPendingTransfers {
            blockedDestinationRemoval = destination
        } else {
            destinationToRemove = destination
        }
    }
}
