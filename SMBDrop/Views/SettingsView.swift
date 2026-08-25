import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DestinationSetupViewModel
    @ObservedObject var transferQueue: TransferQueueViewModel
    @State private var destinationToRemove: DestinationSummary?
    @State private var blockedDestinationRemoval: DestinationSummary?
    @State private var destinationRemovalError: String?
    @AppStorage(SampleContent.defaultsKey) private var isSampleContentOn = false

    private var displayedDestinations: [DestinationSummary] {
        isSampleContentOn ? SampleContent.destinations : viewModel.destinations
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if displayedDestinations.isEmpty {
                        HStack(spacing: 14) {
                            settingsIcon("externaldrive.badge.plus", color: .blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No SMB Shares")
                                    .font(.headline)
                                Text("Add a network folder to start sending and importing files.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(displayedDestinations) { destination in
                            Button {
                                viewModel.beginEditing(destination)
                            } label: {
                                destinationRow(destination)
                            }
                            .disabled(isSampleContentOn)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !isSampleContentOn {
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
                    }

                    Button {
                        viewModel.beginAdding()
                    } label: {
                        Label("Add SMB Share", systemImage: "plus.circle.fill")
                    }
                    .disabled(isSampleContentOn)
                } header: {
                    Text("SMB Shares")
                } footer: {
                    Text("You will choose one of these shares each time you export.")
                }

                Section("Transfers") {
                    NavigationLink {
                        TransferHistoryView(transferQueue: transferQueue)
                    } label: {
                        HStack(spacing: 14) {
                            settingsIcon("clock.arrow.circlepath", color: .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Transfer History")
                                    .foregroundStyle(.primary)
                                Text(transferSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack(spacing: 14) {
                            settingsIcon("info.circle.fill", color: .blue)
                            Text("About SMBDrop")
                        }
                    }
                    Toggle(isOn: $isSampleContentOn) {
                        HStack(spacing: 14) {
                            settingsIcon("sparkles.rectangle.stack.fill", color: .purple)
                            Text("Sample Content")
                        }
                    }
                } header: {
                    Text("App")
                } footer: {
                    Text("Shows sample photos, files, shares, and transfers instead of your own — useful for screenshots. Real transfers pause while this is on.")
                }
            }
            .navigationTitle("Settings")
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

    private var transferSummary: String {
        if let progress = transferQueue.activeProgress, !progress.isComplete {
            return "Sending · \(progress.countText)"
        }
        let failedCount = transferQueue.transfers.filter { $0.status == .failed }.count
        if failedCount > 0 {
            return "\(failedCount) failed item\(failedCount == 1 ? "" : "s") need attention"
        }
        let completedCount = transferQueue.transfers.filter { $0.status == .completed }.count
        return completedCount == 0
            ? "No completed transfers"
            : "\(completedCount) completed transfer\(completedCount == 1 ? "" : "s")"
    }

    private func settingsIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
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
