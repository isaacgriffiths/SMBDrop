import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DestinationSetupViewModel()
    @State private var isConfirmingRemoval = false

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
        } header: {
            Text("Server")
        } footer: {
            Text("For example: host nas.local, share Photos, subfolder iPhone Uploads.")
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
}

#Preview {
    ContentView()
}
