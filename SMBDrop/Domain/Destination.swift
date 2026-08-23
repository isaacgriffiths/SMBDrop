import Foundation

struct Destination: Codable, Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case missingHost
        case invalidHost
        case missingShare
        case missingUsername

        var errorDescription: String? {
            switch self {
            case .missingHost:
                "Enter the host name or IP address of your SMB server."
            case .invalidHost:
                "Enter a valid host name or IP address without smb:// or a folder path."
            case .missingShare:
                "Enter the SMB share name."
            case .missingUsername:
                "Enter the username for your SMB share."
            }
        }
    }

    let host: String
    let share: String
    let subfolder: String
    let username: String

    init(host: String, share: String, subfolder: String, username: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let subfolder = subfolder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !host.isEmpty else { throw ValidationError.missingHost }
        guard !host.contains("://"), !host.contains("/"), !host.contains("\\") else {
            throw ValidationError.invalidHost
        }
        guard !share.isEmpty else { throw ValidationError.missingShare }
        guard !username.isEmpty else { throw ValidationError.missingUsername }

        self.host = host
        self.share = share
        self.subfolder = subfolder
        self.username = username
    }

    var serverURL: URL {
        // The initializer validates that the host cannot alter the URL path.
        URL(string: "smb://\(host)")!
    }

    var remotePath: String {
        subfolder.isEmpty ? "/" : "/\(subfolder)"
    }
}
