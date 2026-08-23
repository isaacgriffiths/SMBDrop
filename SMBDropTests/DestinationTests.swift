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
}
