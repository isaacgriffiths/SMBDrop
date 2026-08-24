import AMSMB2
import Foundation

protocol DestinationConnectionTesting {
    func testConnection(to destination: Destination, password: String) async throws
}

protocol SMBConnectionSession: AnyObject {
    var timeout: TimeInterval { get set }
    func connectShare(name: String, encrypted: Bool) async throws
    func echo() async throws
    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any]
    func disconnectShare(gracefully: Bool) async throws
}

struct SMBConnectionTester: DestinationConnectionTesting {
    typealias SessionFactory = (Destination, String) -> (any SMBConnectionSession)?

    private let tcpProbe: any TCPConnectionProbing
    private let sessionFactory: SessionFactory

    init(
        tcpProbe: any TCPConnectionProbing = TCPConnectionProbe(),
        sessionFactory: @escaping SessionFactory = Self.makeSession
    ) {
        self.tcpProbe = tcpProbe
        self.sessionFactory = sessionFactory
    }

    func testConnection(to destination: Destination, password: String) async throws {
        try await tcpProbe.connect(host: destination.host, port: 445)

        guard let session = sessionFactory(destination, password) else {
            throw SMBConnectionError.invalidServer
        }
        session.timeout = 15
        var connectedToShare = false

        do {
            do {
                try await session.connectShare(name: destination.share, encrypted: false)
            } catch {
                // A share that requires SMB3 encryption denies unsealed connects
                // even with valid credentials; retry sealed like Automatic clients.
                let friendly = SMBConnectionError.friendly(error)
                guard friendly == .authenticationFailed || friendly == .connectionFailed else {
                    throw error
                }
                try await session.connectShare(name: destination.share, encrypted: true)
            }
            connectedToShare = true
            if destination.remotePath == "/" {
                try await session.echo()
            } else {
                let attributes = try await session.attributesOfItem(atPath: destination.remotePath)
                try Self.validateSubfolderAttributes(attributes)
            }
            // Connecting to the share and verifying it are the test. Some
            // libsmb2 builds can surface a stale socket/errno failure after
            // the server has already acknowledged tree disconnect + logoff;
            // cleanup must not turn that verified connection into an auth
            // failure.
            try? await session.disconnectShare(gracefully: true)
        } catch {
            try? await session.disconnectShare(gracefully: false)
            let friendly = SMBConnectionError.friendly(error)
            if !connectedToShare, friendly == .timedOut {
                throw SMBConnectionError.negotiationTimedOut
            }
            throw friendly
        }
    }

    static func validateSubfolderAttributes(_ attributes: [URLResourceKey: Any]) throws {
        guard attributes[.isDirectoryKey] as? Bool == true else {
            throw SMBConnectionError.shareOrFolderMissing
        }
    }

    private static func makeSession(
        destination: Destination,
        password: String
    ) -> (any SMBConnectionSession)? {
        let credential = URLCredential(
            user: destination.username,
            password: password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: destination.serverURL, credential: credential) else {
            return nil
        }
        return AMSMB2ConnectionSession(manager: manager)
    }
}

private final class AMSMB2ConnectionSession: SMBConnectionSession {
    private let manager: SMB2Manager

    init(manager: SMB2Manager) {
        self.manager = manager
    }

    var timeout: TimeInterval {
        get { manager.timeout }
        set { manager.timeout = newValue }
    }

    func connectShare(name: String, encrypted: Bool) async throws {
        try await manager.connectShare(name: name, encrypted: encrypted)
    }

    func echo() async throws {
        try await manager.echo()
    }

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        try await manager.attributesOfItem(atPath: path)
    }

    func disconnectShare(gracefully: Bool) async throws {
        try await manager.disconnectShare(gracefully: gracefully)
    }
}
