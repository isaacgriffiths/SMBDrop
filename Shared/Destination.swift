import Foundation

struct Destination: Codable, Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case missingHost
        case invalidHost
        case invalidPort
        case missingShare
        case invalidShare
        case invalidSubfolder
        case missingUsername

        var errorDescription: String? {
            switch self {
            case .missingHost:
                "Enter the host name or IP address of your SMB server."
            case .invalidHost:
                "Enter a valid host name or IP address without smb:// or a folder path."
            case .invalidPort:
                "Enter a port between 1 and 65535. The standard SMB port is 445."
            case .missingShare:
                "Enter the SMB share name."
            case .invalidShare:
                "Enter only the share name, without slashes or a folder path."
            case .invalidSubfolder:
                "Enter a folder inside the share without . or .. path segments."
            case .missingUsername:
                "Enter the username for your SMB share."
            }
        }
    }

    let host: String
    let port: UInt16
    let share: String
    let subfolder: String
    let username: String

    init(
        host: String,
        port: Int = 445,
        share: String,
        subfolder: String,
        username: String
    ) throws {
        let host = try Self.validatedHost(host)
        guard let port = UInt16(exactly: port), port > 0 else {
            throw ValidationError.invalidPort
        }
        // PhotoSync displays shares as "/share"; accept edge slashes verbatim.
        let share = share.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let subfolder = subfolder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !share.isEmpty else { throw ValidationError.missingShare }
        guard !share.contains("/"), !share.contains("\\") else {
            throw ValidationError.invalidShare
        }
        if !subfolder.isEmpty {
            let subfolderParts = subfolder.split(separator: "/", omittingEmptySubsequences: false)
            guard
                !subfolder.contains("\\"),
                !subfolderParts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else {
                throw ValidationError.invalidSubfolder
            }
        }
        guard !username.isEmpty else { throw ValidationError.missingUsername }

        self.host = host
        self.port = port
        self.share = share
        self.subfolder = subfolder
        self.username = username
    }

    var serverURL: URL {
        // The initializer validates that the host cannot alter the URL path.
        URL(string: "smb://\(host):\(port)")!
    }

    static func validatedHost(_ host: String) throws -> String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ValidationError.missingHost }
        guard !host.contains("://"), !host.contains("/"), !host.contains("\\") else {
            throw ValidationError.invalidHost
        }
        guard
            let components = URLComponents(string: "smb://\(host)"),
            components.scheme == "smb",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.path.isEmpty,
            components.port == nil,
            components.query == nil,
            components.fragment == nil,
            components.url != nil
        else {
            throw ValidationError.invalidHost
        }
        return host
    }

    var remotePath: String {
        subfolder.isEmpty ? "/" : "/\(subfolder)"
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case share
        case subfolder
        case username
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            host: container.decode(String.self, forKey: .host),
            port: Int(try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 445),
            share: container.decode(String.self, forKey: .share),
            subfolder: container.decode(String.self, forKey: .subfolder),
            username: container.decode(String.self, forKey: .username)
        )
    }
}
