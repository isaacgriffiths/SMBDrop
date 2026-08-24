import Darwin
import Foundation

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
        // AMSMB2 can discard libsmb2's result when its context closes on a
        // fatal reply, so prefer the NT status embedded in the message.
        if let status = ntStatus(in: error.localizedDescription),
           let friendly = friendlyNTStatus(status) {
            return friendly
        }
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

    private static func ntStatus(in message: String) -> UInt32? {
        guard let range = message.range(of: #"\(0x[0-9a-fA-F]{8}\)"#, options: .regularExpression)
        else {
            return nil
        }
        return UInt32(message[range].dropFirst(3).dropLast(1), radix: 16)
    }

    private static func friendlyNTStatus(_ status: UInt32) -> SMBConnectionError? {
        switch status {
        case 0xC000_00CC, // STATUS_BAD_NETWORK_NAME
             0xC000_0034, // STATUS_OBJECT_NAME_NOT_FOUND
             0xC000_003A: // STATUS_OBJECT_PATH_NOT_FOUND
            return .shareOrFolderMissing
        case 0xC000_006D, // STATUS_LOGON_FAILURE
             0xC000_006A, // STATUS_WRONG_PASSWORD
             0xC000_0064, // STATUS_NO_SUCH_USER
             0xC000_0071, // STATUS_PASSWORD_EXPIRED
             0xC000_0072, // STATUS_ACCOUNT_DISABLED
             0xC000_0234, // STATUS_ACCOUNT_LOCKED_OUT
             0xC000_0022: // STATUS_ACCESS_DENIED
            return .authenticationFailed
        default:
            return nil
        }
    }
}
