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

    @Published var host = ""
    @Published var share = ""
    @Published var subfolder = ""
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var savedDestination: Destination?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var availableShares: [String] = []
    @Published private(set) var isFindingShares = false
    @Published var isEditing = false

    private let store: DestinationStore
    private let connectionTester: any DestinationConnectionTesting
    private let shareLister: any DestinationShareListing
    private var savedPassword: String?
    private var verifiedForm: FormValues?

    init(
        store: DestinationStore = DestinationStore(),
        connectionTester: any DestinationConnectionTesting = SMBConnectionTester(),
        shareLister: any DestinationShareListing = SMBShareLister()
    ) {
        self.store = store
        self.connectionTester = connectionTester
        self.shareLister = shareLister
        loadSavedDestination()
    }

    var isShowingSetup: Bool {
        savedDestination == nil || isEditing
    }

    var canTest: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isFindingShares
    }

    var savedPath: String {
        guard let destination = savedDestination else { return "" }
        return destination.subfolder.isEmpty
            ? "//\(destination.host)/\(destination.share)"
            : "//\(destination.host)/\(destination.share)/\(destination.subfolder)"
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
    }

    func save() {
        guard canSave else { return }
        do {
            let destination = try currentForm.destination()
            try store.save(destination: destination, password: password)
            savedDestination = destination
            savedPassword = password
            isEditing = false
            connectionState = .idle
            verifiedForm = nil
            availableShares = []
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

    func beginEditing() {
        guard let destination = savedDestination else { return }
        host = destination.host
        share = destination.share
        subfolder = destination.subfolder
        username = destination.username
        password = savedPassword ?? ""
        connectionState = .idle
        verifiedForm = nil
        availableShares = []
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        connectionState = .idle
        verifiedForm = nil
        availableShares = []
    }

    func removeDestination() {
        do {
            try store.remove()
            savedDestination = nil
            savedPassword = nil
            host = ""
            share = ""
            subfolder = ""
            username = ""
            password = ""
            isEditing = false
            connectionState = .idle
            verifiedForm = nil
            availableShares = []
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    private func loadSavedDestination() {
        do {
            guard let saved = try store.load() else { return }
            savedDestination = saved.destination
            savedPassword = saved.password
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    private var currentForm: FormValues {
        FormValues(
            host: host,
            share: share,
            subfolder: subfolder,
            username: username,
            password: password
        )
    }
}

private struct FormValues: Equatable {
    let host: String
    let share: String
    let subfolder: String
    let username: String
    let password: String

    func destination() throws -> Destination {
        try Destination(host: host, share: share, subfolder: subfolder, username: username)
    }
}
