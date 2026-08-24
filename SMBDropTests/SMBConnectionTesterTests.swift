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

    func testFriendlyErrorTrustsTreeConnectStatusOverStaleErrnoCode() {
        // AMSMB2 loses libsmb2's errno when the context closes on a fatal
        // reply and surfaces whichever stale errno the C runtime held, so a
        // missing share can arrive wearing an access-denied POSIX code.
        let error = POSIXError(
            .EACCES,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error code 13: Tree Connect failed with (0xc00000cc) STATUS_BAD_NETWORK_NAME. "
            ]
        )

        XCTAssertEqual(SMBConnectionError.friendly(error), .shareOrFolderMissing)
    }

    func testFriendlyErrorTrustsSessionSetupStatusOverStaleErrnoCode() {
        // libsmb2 maps STATUS_LOGON_FAILURE to ECONNREFUSED, which the POSIX
        // table would misreport as "server could not be reached".
        let error = POSIXError(
            .ECONNREFUSED,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error code 61: Session setup failed with (0xc000006d) STATUS_LOGON_FAILURE"
            ]
        )

        XCTAssertEqual(SMBConnectionError.friendly(error), .authenticationFailed)
    }

    func testConnectionReportsMissingShareWithoutRetryingEncrypted() async throws {
        let destination = try Destination(
            host: "192.168.1.122",
            share: "smb",
            subfolder: "",
            username: "isaac"
        )
        let session = MissingShareSMBSession()
        let tester = SMBConnectionTester(
            tcpProbe: SuccessfulTCPProbe(),
            sessionFactory: { _, _ in session }
        )

        do {
            try await tester.testConnection(to: destination, password: "secret")
            XCTFail("Expected the missing share to be reported")
        } catch {
            XCTAssertEqual(error as? SMBConnectionError, .shareOrFolderMissing)
        }
        XCTAssertEqual(session.connectAttempts, [false])
    }

    func testConnectionRetriesWithEncryptionWhenShareDeniesUnsealedAccess() async throws {
        let destination = try Destination(
            host: "192.168.1.122",
            share: "share",
            subfolder: "",
            username: "isaac"
        )
        let session = EncryptionRequiringSMBSession()
        let tester = SMBConnectionTester(
            tcpProbe: SuccessfulTCPProbe(),
            sessionFactory: { _, _ in session }
        )

        try await tester.testConnection(to: destination, password: "secret")

        XCTAssertEqual(session.connectAttempts, [false, true])
    }
}

private struct SuccessfulTCPProbe: TCPConnectionProbing {
    func connect(host: String, port: UInt16) async throws {}
}

private final class TimingOutSMBSession: SMBConnectionSession {
    var timeout: TimeInterval = 0

    func connectShare(name: String, encrypted: Bool) async throws {
        throw POSIXError(.ETIMEDOUT)
    }

    func echo() async throws {}

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        [:]
    }

    func disconnectShare(gracefully: Bool) async throws {}
}

// Mirrors AMSMB2 surfacing a tree connect against a share that does not exist:
// the NT status lives only in the message while the POSIX code is stale.
private final class MissingShareSMBSession: SMBConnectionSession {
    var timeout: TimeInterval = 0
    private(set) var connectAttempts: [Bool] = []

    func connectShare(name: String, encrypted: Bool) async throws {
        connectAttempts.append(encrypted)
        throw POSIXError(
            .EACCES,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error code 13: Tree Connect failed with (0xc00000cc) STATUS_BAD_NETWORK_NAME. "
            ]
        )
    }

    func echo() async throws {}

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        [:]
    }

    func disconnectShare(gracefully: Bool) async throws {}
}

// Mirrors a server whose share requires SMB3 encryption: connecting with
// sealing disabled fails with access denied even though the credentials are right.
private final class EncryptionRequiringSMBSession: SMBConnectionSession {
    var timeout: TimeInterval = 0
    private(set) var connectAttempts: [Bool] = []

    func connectShare(name: String, encrypted: Bool) async throws {
        connectAttempts.append(encrypted)
        guard encrypted else {
            throw NSError(
                domain: "SMB2ErrorDomain",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Access denied"]
            )
        }
    }

    func echo() async throws {}

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        [:]
    }

    func disconnectShare(gracefully: Bool) async throws {}
}
