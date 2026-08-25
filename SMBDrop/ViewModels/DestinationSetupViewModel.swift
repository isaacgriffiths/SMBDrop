import Combine
import Foundation

@MainActor
final class DestinationSetupViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    enum DestinationRemovalResult: Equatable {
        case removed
        case pendingTransfers
        case failed(String)
    }

    @Published var host = ""
    @Published var port = "445"
    @Published var share = ""
    @Published var subfolder = ""
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var destinations: [DestinationSummary] = []
    @Published private(set) var savedDestination: Destination?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var availableShares: [String] = []
    @Published private(set) var isFindingShares = false
    @Published private(set) var availableFolders: [SMBFolder] = []
    @Published private(set) var folderBrowsePath = ""
    @Published private(set) var folderBrowseError: String?
    @Published private(set) var isLoadingFolders = false
    @Published var isEditing = false

    private let store: DestinationStore
    private let connectionTester: any DestinationConnectionTesting
    private let shareLister: any DestinationShareListing
    private let folderLister: any DestinationFolderListing
    private var savedPassword: String?
    private var editingDestinationID: UUID?
    private var verifiedForm: FormValues?

    init(
        store: DestinationStore = DestinationStore(),
        connectionTester: any DestinationConnectionTesting = SMBConnectionTester(),
        shareLister: any DestinationShareListing = SMBShareLister(),
        folderLister: any DestinationFolderListing = SMBFolderLister()
    ) {
        self.store = store
        self.connectionTester = connectionTester
        self.shareLister = shareLister
        self.folderLister = folderLister
        loadSavedDestination()
    }

    var isShowingSetup: Bool {
        destinations.isEmpty || isEditing
    }

    var canTest: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && connectionState != .testing
    }

    var canSave: Bool {
        connectionState == .success && verifiedForm == currentForm
    }

    var canFindShares: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isFindingShares
    }

    var canBrowseFolders: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isLoadingFolders
    }

    var folderBrowseDisplayPath: String {
        folderBrowsePath.isEmpty ? "/\(share)" : "/\(share)/\(folderBrowsePath)"
    }

    var canBrowseToParentFolder: Bool {
        !folderBrowsePath.isEmpty && !isLoadingFolders
    }

    var folderSelectionError: String? {
        guard case .failure(let message) = connectionState else { return nil }
        return message
    }

    var savedPath: String {
        guard let destination = savedDestination else { return "" }
        let server = destination.port == 445
            ? destination.host
            : "\(destination.host):\(destination.port)"
        return destination.subfolder.isEmpty
            ? "//\(server)/\(destination.share)"
            : "//\(server)/\(destination.share)/\(destination.subfolder)"
    }

    func savedPath(for summary: DestinationSummary) -> String {
        summary.displayPath
    }

    func testConnection() async {
        let form = currentForm
        guard !form.password.isEmpty else {
            connectionState = .failure("Enter the password for your SMB share.")
            return
        }

        let destination: Destination
        do {
            destination = try form.destination()
        } catch {
            connectionState = .failure(error.localizedDescription)
            return
        }

        connectionState = .testing
        do {
            try await connectionTester.testConnection(to: destination, password: form.password)
            verifiedForm = form
            connectionState = .success
        } catch {
            verifiedForm = nil
            connectionState = .failure(error.localizedDescription)
            if error as? SMBConnectionError == .shareOrFolderMissing {
                // Offer the server's actual shares next to the failure so the
                // user taps a real name instead of guessing again.
                availableShares =
                    (try? await shareLister.availableShares(
                        host: form.host,
                        port: form.destinationPort,
                        username: form.username,
                        password: form.password
                    )) ?? []
            }
        }
    }

    func findShares() async {
        guard canFindShares else { return }
        isFindingShares = true
        defer { isFindingShares = false }
        do {
            let shares = try await shareLister.availableShares(
                host: host,
                port: parsedPort ?? 445,
                username: username,
                password: password
            )
            availableShares = shares
            if shares.count == 1, let onlyShare = shares.first {
                share = onlyShare
            } else if shares.isEmpty {
                connectionState = .failure(
                    "The server accepted the sign-in but shows no shares for this account."
                )
            }
        } catch {
            availableShares = []
            connectionState = .failure(error.localizedDescription)
        }
    }

    func selectShare(_ name: String) {
        share = name
        subfolder = ""
        resetFolderBrowser()
    }

    func beginFolderBrowsing() async {
        guard canBrowseFolders else { return }
        connectionState = .idle
        verifiedForm = nil
        do {
            let destination = try currentForm.destination()
            await loadFolders(at: destination.subfolder, destination: destination)
            if folderBrowseError != nil, !destination.subfolder.isEmpty {
                // A manually typed path may be stale or may repeat the share
                // name (for example /share/video). Fall back to the share root
                // so the user can still navigate to the real folder.
                await loadFolders(at: "", destination: destination)
            }
        } catch {
            availableFolders = []
            folderBrowseError = error.localizedDescription
        }
    }

    func browseIntoFolder(_ folder: SMBFolder) async {
        guard let destination = try? currentForm.destination() else { return }
        await loadFolders(at: folder.path, destination: destination)
    }

    func browseToParentFolder() async {
        guard canBrowseToParentFolder,
              let destination = try? currentForm.destination() else { return }
        var components = folderBrowsePath.split(separator: "/").map(String.init)
        _ = components.popLast()
        await loadFolders(at: components.joined(separator: "/"), destination: destination)
    }

    func useBrowsedFolder() async -> Bool {
        let selectedFolder = folderBrowsePath
        subfolder = selectedFolder
        connectionState = .idle
        verifiedForm = nil
        await testConnection()
        guard canSave else { return false }
        save()
        return connectionState == .idle
            && savedDestination?.subfolder == selectedFolder
    }

    func save() {
        guard canSave else { return }
        do {
            let destination = try currentForm.destination()
            let saved = try store.save(
                destination: destination,
                password: password,
                id: editingDestinationID
            )
            reloadDestinations(preferredID: saved.id)
            isEditing = false
            editingDestinationID = nil
            connectionState = .idle
            verifiedForm = nil
            availableShares = []
            resetFolderBrowser()
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    func testSavedDestination() async {
        guard let destination = savedDestination, let password = savedPassword else {
            connectionState = .failure("The saved password is missing. Edit the destination and enter it again.")
            return
        }
        connectionState = .testing
        do {
            try await connectionTester.testConnection(to: destination, password: password)
            connectionState = .success
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    func testDestination(_ summary: DestinationSummary) async {
        do {
            guard let saved = try store.loadAll().first(where: { $0.id == summary.id }) else {
                connectionState = .failure("That SMB share is no longer saved.")
                return
            }
            connectionState = .testing
            try await connectionTester.testConnection(
                to: saved.destination,
                password: saved.password
            )
            connectionState = .success
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    func beginAdding() {
        host = ""
        port = "445"
        share = ""
        subfolder = ""
        username = ""
        password = ""
        savedDestination = destinations.first?.destination
        savedPassword = nil
        editingDestinationID = nil
        connectionState = .idle
        verifiedForm = nil
        availableShares = []
        resetFolderBrowser()
        isEditing = true
    }

    func beginEditing() {
        guard let summary = destinations.first else { return }
        beginEditing(summary)
    }

    func beginEditing(_ summary: DestinationSummary) {
        do {
            guard let saved = try store.loadAll().first(where: { $0.id == summary.id }) else {
                connectionState = .failure("That SMB share is no longer saved.")
                return
            }
            let destination = saved.destination
            host = destination.host
            port = String(destination.port)
            share = destination.share
            subfolder = destination.subfolder
            username = destination.username
            password = saved.password
            savedDestination = destination
            savedPassword = saved.password
            editingDestinationID = saved.id
        } catch {
            connectionState = .failure(error.localizedDescription)
            return
        }
        connectionState = .idle
        verifiedForm = nil
        availableShares = []
        resetFolderBrowser()
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        editingDestinationID = nil
        reloadDestinations()
        connectionState = .idle
        verifiedForm = nil
        availableShares = []
        resetFolderBrowser()
    }

    func removeDestination() async -> DestinationRemovalResult {
        guard let id = editingDestinationID ?? destinations.first?.id else {
            return .failed("That SMB share is no longer saved.")
        }
        return await removeDestination(id)
    }

    func removeDestination(_ id: UUID) async -> DestinationRemovalResult {
        do {
            let outbox = try TransferOutbox.shared()
            guard try await outbox.retireDestination(id) else {
                connectionState = .failure(
                    "Finish, retry, or remove this share's pending transfers before deleting it."
                )
                return .pendingTransfers
            }
            do {
                try store.remove(id: id)
            } catch let storageError {
                do {
                    try await outbox.restoreDestination(id)
                } catch let outboxError {
                    throw DestinationRemovalError.rollbackFailed(
                        storageError: storageError,
                        outboxError: outboxError
                    )
                }
                throw storageError
            }
            reloadDestinations()
            isEditing = false
            editingDestinationID = nil
            connectionState = .idle
            verifiedForm = nil
            availableShares = []
            resetFolderBrowser()
            return .removed
        } catch {
            let message = error.localizedDescription
            connectionState = .failure(message)
            return .failed(message)
        }
    }

    private func loadSavedDestination() {
        reloadDestinations()
    }

    private func reloadDestinations(preferredID: UUID? = nil) {
        do {
            let saved = try store.loadAll()
            destinations = saved.map(\.summary)
            let current = preferredID.flatMap { id in
                saved.first(where: { $0.id == id })
            } ?? saved.first
            savedDestination = current?.destination
            savedPassword = current?.password
        } catch {
            destinations = []
            savedDestination = nil
            savedPassword = nil
            connectionState = .failure(error.localizedDescription)
        }
    }

    private func loadFolders(at path: String, destination: Destination) async {
        isLoadingFolders = true
        folderBrowseError = nil
        defer { isLoadingFolders = false }
        do {
            let folders = try await folderLister.folders(
                at: path,
                in: destination,
                password: password
            )
            folderBrowsePath = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            availableFolders = folders
        } catch {
            availableFolders = []
            folderBrowseError = error.localizedDescription
        }
    }

    private func resetFolderBrowser() {
        availableFolders = []
        folderBrowsePath = ""
        folderBrowseError = nil
        isLoadingFolders = false
    }

    private var currentForm: FormValues {
        FormValues(
            host: host,
            port: port,
            share: share,
            subfolder: subfolder,
            username: username,
            password: password
        )
    }
}

private enum DestinationRemovalError: LocalizedError {
    case rollbackFailed(storageError: Error, outboxError: Error)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let storageError, let outboxError):
            "The SMB share is still saved, but its transfer lock could not be restored. "
                + "Quit and reopen SMBDrop before sending to it again. "
                + "Password cleanup: \(storageError.localizedDescription) "
                + "Transfer recovery: \(outboxError.localizedDescription)"
        }
    }

    private var parsedPort: UInt16? {
        let value = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let integer = Int(value), let port = UInt16(exactly: integer), port > 0 else {
            return nil
        }
        return port
    }
}

private struct FormValues: Equatable {
    let host: String
    let port: String
    let share: String
    let subfolder: String
    let username: String
    let password: String

    var destinationPort: UInt16 {
        UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 445
    }

    func destination() throws -> Destination {
        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Destination.ValidationError.invalidPort
        }
        return try Destination(
            host: host,
            port: port,
            share: share,
            subfolder: subfolder,
            username: username
        )
    }
}
