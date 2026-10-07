import Photos
import SwiftUI

struct AutomaticBackupView: View {
    let destinations: [DestinationSummary]
    @ObservedObject private var backup = AutomaticBackupController.shared
    @ObservedObject private var coordinator = PhotoExportCoordinator.shared
    @ObservedObject var transferQueue: TransferQueueViewModel
    @State private var pendingDestination: DestinationSummary?
    @State private var isChoosingDestination = false
    @State private var chosenDestination: DestinationSummary?
    @State private var isAccessDenied = false

    private var currentDestination: DestinationSummary? {
        destinations.first(where: { $0.id == backup.destinationID })
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { backup.isEnabled },
                    set: { isOn in
                        if isOn {
                            beginEnabling()
                        } else {
                            backup.disable()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Back Up Photos & Videos")
                        Text("Sends every new photo and video to one share.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(destinations.isEmpty)
            } footer: {
                if destinations.isEmpty {
                    Text("Add an SMB share first.")
                }
            }

            if backup.isEnabled {
                Section("Backing Up To") {
                    Button {
                        isChoosingDestination = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(currentDestination?.displayName ?? "Choose a Share")
                                    .foregroundStyle(.primary)
                                if let currentDestination {
                                    Text(currentDestination.displayPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    if let problem = backup.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    } else if coordinator.isBackupPaused, let message = transferQueue.message {
                        Label(message, systemImage: "pause.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Waiting to Send", value: coordinator.pendingBackupCount.formatted())
                    LabeledContent("Sent or Queued", value: backup.handedOffCount.formatted())
                    LabeledContent("Last Checked") {
                        if let lastRunDate = backup.lastRunDate {
                            Text(lastRunDate, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    Button {
                        Task { await backup.run(userInitiated: true) }
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(backup.problem != nil && currentDestination == nil)
                } header: {
                    Text("Status")
                } footer: {
                    Text("iOS decides when apps may run in the background. SMBDrop backs up whenever you open it, and overnight while your iPhone is charging and can reach the share. A file already on the share with the same name and size counts as backed up; a different file with the same name is never overwritten.")
                }
            }
        }
        .navigationTitle("Automatic Backup")
        .sheet(isPresented: $isChoosingDestination, onDismiss: {
            // The scope question waits for the sheet to finish closing;
            // SwiftUI drops a dialog presented mid-dismissal.
            pendingDestination = chosenDestination
            chosenDestination = nil
        }) {
            DestinationPickerSheet(
                destinations: destinations,
                itemCount: 0,
                title: "Back Up To"
            ) { destination in
                chosenDestination = destination
            }
        }
        .confirmationDialog(
            "What Should Be Backed Up?",
            isPresented: Binding(
                get: { pendingDestination != nil },
                set: { if !$0 { pendingDestination = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDestination
        ) { destination in
            Button("Everything in My Library") {
                enable(destination, scope: .wholeLibrary)
            }
            Button("Only New Photos & Videos") {
                enable(destination, scope: .newItemsOnly)
            }
            Button("Cancel", role: .cancel) {}
        } message: { destination in
            Text("Backing up to \(destination.displayName). Everything sends your whole library first, which can take a while; Only New starts from today.")
        }
        .alert("Full Photo Access Needed", isPresented: $isAccessDenied) {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic Backup needs access to all photos so it can find new ones. Choose Full Access in Settings › Apps › SMBDrop › Photos.")
        }
    }

    private func beginEnabling() {
        if destinations.count == 1 {
            pendingDestination = destinations.first
        } else {
            isChoosingDestination = true
        }
    }

    private func enable(_ destination: DestinationSummary, scope: AutomaticBackupController.Scope) {
        pendingDestination = nil
        Task {
            if !(await backup.enable(destinationID: destination.id, scope: scope)) {
                isAccessDenied = true
            }
        }
    }
}
