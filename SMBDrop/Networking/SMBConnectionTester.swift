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
            try await session.disconnectShare(gracefully: true)
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

enum SMBConnectionError: LocalizedError, Equatable {
    case invalidServer
    case localNetworkDenied
    case tcpTimedOut
    case authenticationFailed
    case serverUnavailable
    case timedOut
    case negotiationTimedOut
    case shareOrFolderMissing
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "That server address is not valid. Enter a host name or IP address."
        case .localNetworkDenied:
            return "SMBDrop cannot access your network. Enable Local Network in Settings > Apps > SMBDrop, then try again."
        case .tcpTimedOut:
            return "This iPhone could not open port 445 on the server. Check Local Network permission, Wi-Fi or Tailscale, and the server address."
        case .authenticationFailed:
            return "The server rejected that username or password. Check both and try again."
        case .serverUnavailable:
            return "The server could not be reached. Check that this iPhone is on the same network and that SMB is running."
        case .timedOut:
            return "The server did not respond in time. Check its address and your Wi-Fi connection."
        case .negotiationTimedOut:
            return "This iPhone reached the server on port 445, but SMB negotiation did not finish. SMBDrop will use this result to choose a compatible security mode."
        case .shareOrFolderMissing:
            return "The share or subfolder was not found. Check both names and try again."
        case .connectionFailed:
            return "SMBDrop could not connect. Check the server, share, and sign-in details, then try again."
        }
    }

    static func friendly(_ error: any Error) -> SMBConnectionError {
        if let error = error as? SMBConnectionError {
            return error
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case EACCES, EPERM:
                return .authenticationFailed
            case ETIMEDOUT:
                return .timedOut
            case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH:
                return .serverUnavailable
            case ENOENT:
                return .shareOrFolderMissing
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("logon") || message.contains("authentication") || message.contains("access denied") {
            return .authenticationFailed
        }
        if message.contains("timed out") || message.contains("timeout") {
            return .timedOut
        }
        if message.contains("not found") || message.contains("no such file") {
            return .shareOrFolderMissing
        }
        if message.contains("refused") || message.contains("unreachable") || message.contains("no route") {
            return .serverUnavailable
        }
        return .connectionFailed
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
