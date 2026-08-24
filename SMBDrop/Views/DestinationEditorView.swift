import SwiftUI

struct DestinationEditorView: View {
    @ObservedObject var viewModel: DestinationSetupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingFolderBrowser = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect your storage")
                                .font(.headline)
                            Text("Test these exact details before saving.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Server") {
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
                            if viewModel.isLoadingFolders { ProgressView() }
                        }
                    }
                    .disabled(!viewModel.canBrowseFolders)

                    Button {
                        Task { await viewModel.findShares() }
                    } label: {
                        HStack {
                            Label("Find Shares", systemImage: "magnifyingglass")
                            Spacer()
                            if viewModel.isFindingShares { ProgressView() }
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
                                }
                            }
                        }
                    }
                }

                Section("Sign In") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        Task { await viewModel.testConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "bolt.horizontal.circle")
                            Spacer()
                            if viewModel.connectionState == .testing { ProgressView() }
                        }
                    }
                    .disabled(!viewModel.canTest)
                    connectionStatus
                } footer: {
                    Text("Save becomes available after these exact details connect successfully.")
                }
            }
            .navigationTitle("SMB Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEditing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.save()
                        if !viewModel.isEditing { dismiss() }
                    }
                    .disabled(!viewModel.canSave)
                }
            }
            .sheet(isPresented: $isShowingFolderBrowser) {
                folderBrowser
            }
        }
    }

    private var folderBrowser: some View {
        NavigationStack {
            List {
                Section("Current Folder") {
                    Label(viewModel.folderBrowseDisplayPath, systemImage: "folder.fill")
                        .font(.subheadline.monospaced())

                    if viewModel.connectionState == .testing {
                        ProgressView("Verifying and saving…")
                    } else if let message = viewModel.folderSelectionError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

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
                    Button("Cancel") { isShowingFolderBrowser = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use & Save") {
                        Task {
                            if await viewModel.useBrowsedFolder() {
                                isShowingFolderBrowser = false
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        viewModel.isLoadingFolders
                            || viewModel.folderBrowseError != nil
                            || viewModel.connectionState == .testing
                    )
                }
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
}
