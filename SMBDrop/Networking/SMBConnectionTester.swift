import AMSMB2
import Foundation

protocol DestinationConnectionTesting {
    func testConnection(to destination: Destination, password: String) async throws
}

struct SMBConnectionTester: DestinationConnectionTesting {
    func testConnection(to destination: Destination, password: String) async throws {
        let credential = URLCredential(
            user: destination.username,
            password: password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: destination.serverURL, credential: credential) else {
            throw SMBConnectionError.invalidServer
        }
        manager.timeout = 15

        do {
            try await manager.connectShare(name: destination.share)
            if destination.remotePath == "/" {
                try await manager.echo()
            } else {
                let attributes = try await manager.attributesOfItem(atPath: destination.remotePath)
                try Self.validateSubfolderAttributes(attributes)
            }
            try await manager.disconnectShare(gracefully: true)
        } catch {
            try? await manager.disconnectShare(gracefully: false)
            throw SMBConnectionError.friendly(error)
        }
    }

    static func validateSubfolderAttributes(_ attributes: [URLResourceKey: Any]) throws {
        guard attributes[.isDirectoryKey] as? Bool == true else {
            throw SMBConnectionError.shareOrFolderMissing
        }
    }
}

enum SMBConnectionError: LocalizedError, Equatable {
    case invalidServer
    case authenticationFailed
    case serverUnavailable
    case timedOut
    case shareOrFolderMissing
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "That server address is not valid. Enter a host name or IP address."
        case .authenticationFailed:
            return "The server rejected that username or password. Check both and try again."
        case .serverUnavailable:
            return "The server could not be reached. Check that this iPhone is on the same network and that SMB is running."
        case .timedOut:
            return "The server did not respond in time. Check its address and your Wi-Fi connection."
        case .shareOrFolderMissing:
            return "The share or subfolder was not found. Check both names and try again."
        case .connectionFailed:
            return "SMBDrop could not connect. Check the server, share, and sign-in details, then try again."
        }
    }

    static func friendly(_ error: any Error) -> SMBConnectionError {
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
