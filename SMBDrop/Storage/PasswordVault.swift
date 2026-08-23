import Foundation
import Security

protocol PasswordVault {
    func readPassword() throws -> String?
    func savePassword(_ password: String) throws
    func removePassword() throws
}

struct KeychainPasswordVault: PasswordVault {
    private let service = "com.isaacgriffiths.smbdrop.destination"
    private let account = "smb-password"
    private let accessGroup = "LKAFZ4ANSY.com.isaacgriffiths.smbdrop.shared"

    func readPassword() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
        guard
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidPasswordData
        }
        return password
    }

    func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    func removePassword() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}

private enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidPasswordData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            if let message = SecCopyErrorMessageString(status, nil) {
                return "The password could not be accessed in Keychain: \(message)"
            }
            return "The password could not be accessed in Keychain (\(status))."
        case .invalidPasswordData:
            return "The password stored in Keychain is not valid text."
        }
    }
}
