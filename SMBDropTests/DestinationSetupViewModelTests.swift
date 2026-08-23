import XCTest
@testable import SMBDrop

@MainActor
final class DestinationSetupViewModelTests: XCTestCase {
    func testConnectionEnablesSavingOnlyForExactTestedDetails() async throws {
        let suiteName = "SMBDropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DestinationStore(
            defaults: defaults,
            passwordVault: ViewModelMemoryPasswordVault()
        )
        let viewModel = DestinationSetupViewModel(
            store: store,
            connectionTester: SuccessfulConnectionTester()
        )
        viewModel.host = "nas.local"
        viewModel.share = "Photos"
        viewModel.subfolder = "iPhone Uploads"
        viewModel.username = "isaac"
        viewModel.password = "super-secret"

        XCTAssertFalse(viewModel.canSave)
        await viewModel.testConnection()
        XCTAssertTrue(viewModel.canSave)

        viewModel.subfolder = "Different Folder"
        XCTAssertFalse(viewModel.canSave)
    }
}

private struct SuccessfulConnectionTester: DestinationConnectionTesting {
    func testConnection(to destination: Destination, password: String) async throws {}
}

private final class ViewModelMemoryPasswordVault: PasswordVault {
    private var password: String?

    func readPassword() throws -> String? { password }
    func savePassword(_ password: String) throws { self.password = password }
    func removePassword() throws { password = nil }
}
