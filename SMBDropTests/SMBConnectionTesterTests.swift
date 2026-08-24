import XCTest
@testable import SMBDrop

final class SMBConnectionTesterTests: XCTestCase {
    func testConnectionRejectsAFileAsTheConfiguredSubfolder() {
        XCTAssertThrowsError(
            try SMBConnectionTester.validateSubfolderAttributes([
                .isDirectoryKey: false
            ])
        ) { error in
            XCTAssertEqual(error as? SMBConnectionError, .shareOrFolderMissing)
        }
    }

    func testConnectionDistinguishesSMBNegotiationTimeoutAfterTCPConnects() async throws {
        let destination = try Destination(
            host: "192.168.1.122",
            share: "share",
            subfolder: "",
            username: "isaac"
        )
        let tester = SMBConnectionTester(
            tcpProbe: SuccessfulTCPProbe(),
            sessionFactory: { _, _ in TimingOutSMBSession() }
        )

        do {
            try await tester.testConnection(to: destination, password: "secret")
            XCTFail("Expected SMB negotiation to time out")
        } catch {
            XCTAssertEqual(error as? SMBConnectionError, .negotiationTimedOut)
        }
    }
}

private struct SuccessfulTCPProbe: TCPConnectionProbing {
    func connect(host: String, port: UInt16) async throws {}
}

private final class TimingOutSMBSession: SMBConnectionSession {
    var timeout: TimeInterval = 0

    func connectShare(name: String) async throws {
        throw POSIXError(.ETIMEDOUT)
    }

    func echo() async throws {}

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        [:]
    }

    func disconnectShare(gracefully: Bool) async throws {}
}
