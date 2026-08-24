import Foundation

struct DestinationSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: Destination

    var displayName: String {
        destination.subfolder.isEmpty
            ? destination.share
            : destination.subfolder.split(separator: "/").last.map(String.init) ?? destination.share
    }

    var displayPath: String {
        destination.subfolder.isEmpty
            ? "//\(destination.host)/\(destination.share)"
            : "//\(destination.host)/\(destination.share)/\(destination.subfolder)"
    }
}

struct SavedDestination: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: Destination
    let password: String

    var summary: DestinationSummary {
        DestinationSummary(id: id, destination: destination)
    }
}

struct DestinationStore {
    static let appGroup = SMBDropAppGroup.identifier

    private let defaults: UserDefaults
    private let passwordVault: any PasswordVault
    private let legacyDestinationKey = "savedDestination"
    private let destinationsKey = "savedDestinations.v2"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: DestinationStore.appGroup)!,
        passwordVault: any PasswordVault = KeychainPasswordVault()
    ) {
        self.defaults = defaults
        self.passwordVault = passwordVault
    }

    /// Loads every configured share. Reading this interface also performs the
    /// one-time migration from the original single-destination representation.
    func loadAll() throws -> [SavedDestination] {
        if let data = defaults.data(forKey: destinationsKey) {
            let summaries = try JSONDecoder().decode([DestinationSummary].self, from: data)
            let passwords = try readPasswords(for: summaries)
            return try summaries.map { summary in
                guard let password = passwords[summary.id.uuidString] else {
                    throw StorageError.passwordMissing
                }
                return SavedDestination(
                    id: summary.id,
                    destination: summary.destination,
                    password: password
                )
            }
        }

        guard let legacyData = defaults.data(forKey: legacyDestinationKey) else {
            return []
        }
        let destination = try JSONDecoder().decode(Destination.self, from: legacyData)
        guard let password = try passwordVault.readPassword() else {
            throw StorageError.passwordMissing
        }

        let migrated = SavedDestination(
            id: UUID(),
            destination: destination,
            password: password
        )
        try persist([migrated])
        defaults.removeObject(forKey: legacyDestinationKey)
        return [migrated]
    }

    /// Compatibility convenience for callers that only need the first share.
    func load() throws -> SavedDestination? {
        try loadAll().first
    }

    @discardableResult
    func save(
        destination: Destination,
        password: String,
        id: UUID? = nil
    ) throws -> SavedDestination {
        var destinations = try loadAll()
        let destinationID = id ?? UUID()
        let saved = SavedDestination(
            id: destinationID,
            destination: destination,
            password: password
        )

        if let index = destinations.firstIndex(where: { $0.id == destinationID }) {
            destinations[index] = saved
        } else {
            destinations.append(saved)
        }
        try persist(destinations)
        return saved
    }

    func remove(id: UUID) throws {
        let remaining = try loadAll().filter { $0.id != id }
        if remaining.isEmpty {
            try passwordVault.removePassword()
            defaults.removeObject(forKey: destinationsKey)
        } else {
            try persist(remaining)
        }
    }

    /// Compatibility convenience that removes every configured share.
    func remove() throws {
        try passwordVault.removePassword()
        defaults.removeObject(forKey: destinationsKey)
        defaults.removeObject(forKey: legacyDestinationKey)
    }

    private func readPasswords(
        for summaries: [DestinationSummary]
    ) throws -> [String: String] {
        guard let stored = try passwordVault.readPassword() else {
            if summaries.isEmpty { return [:] }
            throw StorageError.passwordMissing
        }
        if let data = stored.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(PasswordEnvelope.self, from: data) {
            return envelope.passwords
        }

        // A v2 destination list can coexist briefly with the old single raw
        // password if a previous migration was interrupted between writes.
        if summaries.count == 1, let id = summaries.first?.id {
            return [id.uuidString: stored]
        }
        throw StorageError.passwordMissing
    }

    private func persist(_ destinations: [SavedDestination]) throws {
        let summaries = destinations.map(\.summary)
        let passwords = Dictionary(
            uniqueKeysWithValues: destinations.map { ($0.id.uuidString, $0.password) }
        )
        let passwordData = try JSONEncoder().encode(PasswordEnvelope(passwords: passwords))
        guard let passwordPayload = String(data: passwordData, encoding: .utf8) else {
            throw StorageError.passwordEncodingFailed
        }

        // Store secrets first. A crash can leave an unused Keychain entry, but
        // can never expose a destination whose password was not committed.
        try passwordVault.savePassword(passwordPayload)
        defaults.set(try JSONEncoder().encode(summaries), forKey: destinationsKey)
    }

    private struct PasswordEnvelope: Codable {
        let passwords: [String: String]
    }
}

extension DestinationStore {
    enum StorageError: LocalizedError {
        case passwordMissing
        case passwordEncodingFailed

        var errorDescription: String? {
            switch self {
            case .passwordMissing:
                "A saved SMB password is missing. Edit that share and enter it again."
            case .passwordEncodingFailed:
                "SMBDrop could not securely encode the saved passwords."
            }
        }
    }
}
