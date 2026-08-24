import XCTest
@testable import SMBDrop

final class DestinationTests: XCTestCase {
    func testValidDestinationProducesCanonicalConnectionValues() throws {
        let destination = try Destination(
            host: " nas.local ",
            share: " Photos ",
            subfolder: " /iPhone Uploads/ ",
            username: " isaac "
        )

        XCTAssertEqual(destination.host, "nas.local")
        XCTAssertEqual(destination.share, "Photos")
        XCTAssertEqual(destination.subfolder, "iPhone Uploads")
        XCTAssertEqual(destination.username, "isaac")
        XCTAssertEqual(destination.serverURL.absoluteString, "smb://nas.local")
        XCTAssertEqual(destination.remotePath, "/iPhone Uploads")
    }

    func testSavedDestinationLoadsWithPasswordFromVault() throws {
        let suiteName = "SMBDropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let passwordVault = MemoryPasswordVault()
        let store = DestinationStore(defaults: defaults, passwordVault: passwordVault)
        let destination = try Destination(
            host: "nas.local",
            share: "Photos",
            subfolder: "iPhone Uploads",
            username: "isaac"
        )

        try store.save(destination: destination, password: "super-secret")

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.destination, destination)
        XCTAssertEqual(saved.password, "super-secret")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains("super-secret")
        })
    }

    func testShareNameWithEdgeSlashesNormalisesToBareName() throws {
        // PhotoSync displays the share as "/share"; migrating users type it verbatim.
        let leading = try Destination(
            host: "nas.local",
            share: "/Photos",
            subfolder: "",
            username: "isaac"
        )
        XCTAssertEqual(leading.share, "Photos")

        let trailing = try Destination(
            host: "nas.local",
            share: "Photos/",
            subfolder: "",
            username: "isaac"
        )
        XCTAssertEqual(trailing.share, "Photos")

        XCTAssertEqual(leading, trailing)
    }

    func testDestinationRejectsUnsafeShareAndSubfolderPaths() throws {
        XCTAssertThrowsError(
            try Destination(
                host: "nas.local",
                share: "Photos/Private",
                subfolder: "",
                username: "isaac"
            )
        ) { error in
            XCTAssertEqual(error as? Destination.ValidationError, .invalidShare)
        }

        XCTAssertThrowsError(
            try Destination(
                host: "nas.local",
                share: "Photos",
                subfolder: "Uploads/../Private",
                username: "isaac"
            )
        ) { error in
            XCTAssertEqual(error as? Destination.ValidationError, .invalidSubfolder)
        }

        XCTAssertThrowsError(
            try Destination(
                host: "nas.local:1445",
                share: "Photos",
                subfolder: "",
                username: "isaac"
            )
        ) { error in
            XCTAssertEqual(error as? Destination.ValidationError, .invalidHost)
        }
    }
}

private final class MemoryPasswordVault: PasswordVault {
    private var password: String?

    func readPassword() throws -> String? {
        password
    }

    func savePassword(_ password: String) throws {
        self.password = password
    }

    func removePassword() throws {
        password = nil
    }
}
