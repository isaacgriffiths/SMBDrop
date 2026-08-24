import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DestinationSetupViewModel()
    @StateObject private var transferQueue = TransferQueueViewModel()
    @State private var isConfirmingRemoval = false
    @State private var isShowingFolderBrowser = false

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isShowingSetup {
                    setupForm
                } else {
                    savedDestination
                }
            }
            .navigationTitle(viewModel.isShowingSetup ? "Add SMB Share" : "SMBDrop")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if viewModel.isShowingSetup {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.save()
                            Task { await transferQueue.resume() }
                        }
                        .disabled(!viewModel.canSave)
                    }
                    if viewModel.savedDestination != nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                viewModel.cancelEditing()
                            }
                        }
                    }
                }
            }
            .alert("Remove Destination?", isPresented: $isConfirmingRemoval) {
                Button("Remove", role: .destructive) {
                    viewModel.removeDestination()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved server details and password from this iPhone.")
            }
            .sheet(isPresented: $isShowingFolderBrowser) {
                folderBrowser
            }
            .task {
                await transferQueue.resume()
            }
        }
    }

    @ViewBuilder
    private var setupForm: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect your storage")
                        .font(.headline)
                    Text("Enter the details used to open this share on your network.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        Section {
            TextField("Host or IP address", text: $viewModel.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
            TextField("Share name", text: $viewModel.share)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Subfolder (optional)", text: $viewModel.subfolder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                isShowingFolderBrowser = true
                Task { await viewModel.beginFolderBrowsing() }
            } label: {
                HStack {
                    Label("Browse Folders", systemImage: "folder")
                    Spacer()
                    if viewModel.isLoadingFolders {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.canBrowseFolders)
            Button {
                Task { await viewModel.findShares() }
            } label: {
                HStack {
                    Label("Find Shares", systemImage: "magnifyingglass")
                    Spacer()
                    if viewModel.isFindingShares {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.canFindShares)
            ForEach(viewModel.availableShares, id: \.self) { name in
                Button {
                    viewModel.selectShare(name)
                } label: {
                    HStack {
                        Label(name, systemImage: "externaldrive")
                            .foregroundStyle(.primary)
                        Spacer()
                        if viewModel.share == name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text(
                viewModel.availableShares.isEmpty
                    ? "Fill in the address and Sign In below, then Find Shares lists this server's shares to pick from."
                    : "Tap a share to use it."
            )
        }

        Section {
            TextField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
        } header: {
            Text("Sign In")
        } footer: {
            Label("Your password is stored in this iPhone's Keychain.", systemImage: "lock.fill")
        }

        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if viewModel.connectionState == .testing {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.canTest)

            connectionStatus
        } footer: {
            Text("Save becomes available after these exact details connect successfully.")
        }
    }

    private var folderBrowser: some View {
        NavigationStack {
            List {
                Section("Current Folder") {
                    Label(viewModel.folderBrowseDisplayPath, systemImage: "folder.fill")
                        .font(.subheadline.monospaced())

                    if viewModel.canBrowseToParentFolder {
                        Button {
                            Task { await viewModel.browseToParentFolder() }
                        } label: {
                            Label("Up One Level", systemImage: "arrow.up.left")
                        }
                    }
                }

                Section("Folders") {
                    if viewModel.isLoadingFolders {
                        HStack {
                            Spacer()
                            ProgressView("Loading folders…")
                            Spacer()
                        }
                    } else if let message = viewModel.folderBrowseError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if viewModel.availableFolders.isEmpty {
                        ContentUnavailableView(
                            "No Subfolders",
                            systemImage: "folder",
                            description: Text("You can use the current folder.")
                        )
                    } else {
                        ForEach(viewModel.availableFolders) { folder in
                            Button {
                                Task { await viewModel.browseIntoFolder(folder) }
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingFolderBrowser = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Folder") {
                        viewModel.selectBrowsedFolder()
                        isShowingFolderBrowser = false
                    }
                    .disabled(viewModel.isLoadingFolders || viewModel.folderBrowseError != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var savedDestination: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Destination Ready")
                    .font(.title2.bold())
                Text("SMBDrop will send files to this share.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }

        if let destination = viewModel.savedDestination {
            Section("Destination") {
                LabeledContent("Path", value: viewModel.savedPath)
                LabeledContent("Username", value: destination.username)
            }
        }

        if !transferQueue.transfers.isEmpty || transferQueue.isDraining {
            Section("Transfers") {
                if transferQueue.isDraining {
                    HStack {
                        ProgressView()
                        Text("Uploading queued items…")
                    }
                }

                ForEach(transferQueue.transfers) { transfer in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: transferIcon(transfer.status))
                                .foregroundStyle(transferColor(transfer.status))
                            Text(transfer.remoteFilename ?? transfer.filename)
                                .lineLimit(1)
                            Spacer()
                            Text(transferStatus(transfer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if transfer.status == .uploading {
                            ProgressView(
                                value: Double(transfer.bytesTransferred),
                                total: Double(max(1, transfer.byteCount))
                            )
                        }

                        if let error = transfer.errorMessage, transfer.status == .failed {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if transfer.status == .failed {
                            Button("Retry") {
                                Task { await transferQueue.retry(transfer.id) }
                            }
                        } else if transfer.status == .completed {
                            Button("Remove from History", role: .destructive) {
                                Task { await transferQueue.remove(transfer.id) }
                            }
                            .font(.caption)
                        }
                    }
                }

                if let message = transferQueue.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }

        Section {
            Button {
                Task { await viewModel.testSavedDestination() }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if viewModel.connectionState == .testing {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.connectionState == .testing)

            connectionStatus
        }

        Section {
            Button("Edit Destination") {
                viewModel.beginEditing()
            }
            Button("Remove Destination", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch viewModel.connectionState {
        case .idle, .testing:
            EmptyView()
        case .success:
            Label("Connection successful", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
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

    private func transferStatus(_ transfer: Transfer) -> String {
        switch transfer.status {
        case .queued:
            "Queued"
        case .uploading:
            "\(Int((Double(transfer.bytesTransferred) / Double(max(1, transfer.byteCount))) * 100))%"
        case .failed:
            "Failed"
        case .completed:
            "Uploaded"
        }
    }
}

#Preview {
    ContentView()
}
