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

    func testFindSharesRequiresHostAndSignInDetails() throws {
        let viewModel = try makeViewModel(shareLister: FakeShareLister(shares: ["share"]))
        viewModel.host = "192.168.1.122"
        viewModel.username = "isaac"

        XCTAssertFalse(viewModel.canFindShares)
        viewModel.password = "super-secret"
        XCTAssertTrue(viewModel.canFindShares)
    }

    func testFindSharesListsServerSharesForTapToSelect() async throws {
        let viewModel = try makeViewModel(
            shareLister: FakeShareLister(shares: ["media", "share"])
        )
        viewModel.host = "192.168.1.122"
        viewModel.username = "isaac"
        viewModel.password = "super-secret"

        await viewModel.findShares()

        XCTAssertEqual(viewModel.availableShares, ["media", "share"])
        viewModel.selectShare("share")
        XCTAssertEqual(viewModel.share, "share")
    }

    func testFindSharesFillsTheShareFieldWhenOnlyOneExists() async throws {
        let viewModel = try makeViewModel(shareLister: FakeShareLister(shares: ["share"]))
        viewModel.host = "192.168.1.122"
        viewModel.username = "isaac"
        viewModel.password = "super-secret"

        await viewModel.findShares()

        XCTAssertEqual(viewModel.share, "share")
    }

    func testMissingShareFailureSuggestsTheServersActualShares() async throws {
        let viewModel = try makeViewModel(
            connectionTester: FailingConnectionTester(error: .shareOrFolderMissing),
            shareLister: FakeShareLister(shares: ["share"])
        )
        viewModel.host = "192.168.1.122"
        viewModel.share = "SHAREDRIVE"
        viewModel.username = "isaac"
        viewModel.password = "super-secret"

        await viewModel.testConnection()

        guard case .failure(let message) = viewModel.connectionState else {
            return XCTFail("Expected the missing share failure to be reported")
        }
        XCTAssertEqual(message, SMBConnectionError.shareOrFolderMissing.errorDescription)
        XCTAssertEqual(viewModel.availableShares, ["share"])
    }

    func testBrowseFoldersNavigatesAndSelectsARealSubfolder() async throws {
        let folderLister = FakeFolderLister(foldersByPath: [
            "": [SMBFolder(name: "Video", path: "Video")],
            "Video": [SMBFolder(name: "phone", path: "Video/phone")],
        ])
        let viewModel = try makeViewModel(
            shareLister: FakeShareLister(shares: ["share"]),
            folderLister: folderLister
        )
        viewModel.host = "192.168.1.122"
        viewModel.share = "share"
        viewModel.username = "isaac"
        viewModel.password = "super-secret"

        await viewModel.beginFolderBrowsing()
        XCTAssertEqual(viewModel.availableFolders.map(\.name), ["Video"])

        await viewModel.browseIntoFolder(try XCTUnwrap(viewModel.availableFolders.first))
        XCTAssertEqual(viewModel.folderBrowsePath, "Video")
        XCTAssertEqual(viewModel.availableFolders.map(\.name), ["phone"])

        let didSave = await viewModel.useBrowsedFolder()

        XCTAssertTrue(didSave)
        XCTAssertEqual(viewModel.subfolder, "Video")
        XCTAssertEqual(viewModel.savedDestination?.subfolder, "Video")
        XCTAssertFalse(viewModel.isShowingSetup)
        XCTAssertEqual(viewModel.connectionState, .idle)
    }

    private func makeViewModel(
        connectionTester: any DestinationConnectionTesting = SuccessfulConnectionTester(),
        shareLister: any DestinationShareListing,
        folderLister: any DestinationFolderListing = FakeFolderLister(foldersByPath: [:])
    ) throws -> DestinationSetupViewModel {
        let suiteName = "SMBDropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = DestinationStore(
            defaults: defaults,
            passwordVault: ViewModelMemoryPasswordVault()
        )
        return DestinationSetupViewModel(
            store: store,
            connectionTester: connectionTester,
            shareLister: shareLister,
            folderLister: folderLister
        )
    }
}

private struct SuccessfulConnectionTester: DestinationConnectionTesting {
    func testConnection(to destination: Destination, password: String) async throws {}
}

private struct FailingConnectionTester: DestinationConnectionTesting {
    let error: SMBConnectionError

    func testConnection(to destination: Destination, password: String) async throws {
        throw error
    }
}

private struct FakeShareLister: DestinationShareListing {
    let shares: [String]

    func availableShares(
        host: String,
        port: UInt16,
        username: String,
        password: String
    ) async throws -> [String] {
        shares
    }
}

private struct FakeFolderLister: DestinationFolderListing {
    let foldersByPath: [String: [SMBFolder]]

    func folders(
        at subfolder: String,
        in destination: Destination,
        password: String
    ) async throws -> [SMBFolder] {
        foldersByPath[subfolder] ?? []
    }
}

private final class ViewModelMemoryPasswordVault: PasswordVault {
    private var password: String?

    func readPassword() throws -> String? { password }
    func savePassword(_ password: String) throws { self.password = password }
    func removePassword() throws { password = nil }
}
