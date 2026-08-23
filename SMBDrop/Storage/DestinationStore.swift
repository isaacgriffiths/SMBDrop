import Foundation

struct SavedDestination: Equatable, Sendable {
    let destination: Destination
    let password: String
}

struct DestinationStore {
    static let appGroup = "group.com.isaacgriffiths.smbdrop"

    private let defaults: UserDefaults
    private let passwordVault: any PasswordVault
    private let destinationKey = "savedDestination"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: DestinationStore.appGroup)!,
        passwordVault: any PasswordVault = KeychainPasswordVault()
    ) {
        self.defaults = defaults
        self.passwordVault = passwordVault
    }

    func load() throws -> SavedDestination? {
        guard let data = defaults.data(forKey: destinationKey) else {
            return nil
        }

        let destination = try JSONDecoder().decode(Destination.self, from: data)
        guard let password = try passwordVault.readPassword() else {
            throw StorageError.passwordMissing
        }
        return SavedDestination(destination: destination, password: password)
    }

    func save(destination: Destination, password: String) throws {
        let data = try JSONEncoder().encode(destination)
        try passwordVault.savePassword(password)
        defaults.set(data, forKey: destinationKey)
    }

    func remove() throws {
        try passwordVault.removePassword()
        defaults.removeObject(forKey: destinationKey)
    }
}

extension DestinationStore {
    enum StorageError: LocalizedError {
        case passwordMissing

        var errorDescription: String? {
            "The saved SMB password is missing. Edit the destination and enter it again."
        }
    }
}
