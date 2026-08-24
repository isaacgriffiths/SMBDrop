import AMSMB2
import Foundation

struct SMBFolder: Equatable, Identifiable, Sendable {
    let name: String
    let path: String

    var id: String { path }
}

protocol DestinationFolderListing {
    func folders(
        at subfolder: String,
        in destination: Destination,
        password: String
    ) async throws -> [SMBFolder]
}

struct SMBFolderLister: DestinationFolderListing {
    func folders(
        at subfolder: String,
        in destination: Destination,
        password: String
    ) async throws -> [SMBFolder] {
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
            try await connect(manager, share: destination.share)
            let relativePath = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let remotePath = relativePath.isEmpty ? "/" : "/\(relativePath)"
            let entries = try await manager.contentsOfDirectory(atPath: remotePath)
            let folders = entries.compactMap { attributes -> SMBFolder? in
                guard attributes[.isDirectoryKey] as? Bool == true,
                      let name = attributes[.nameKey] as? String,
                      !name.isEmpty,
                      name != ".",
                      name != ".." else {
                    return nil
                }
                let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                return SMBFolder(name: name, path: path)
            }
            try? await manager.disconnectShare(gracefully: true)
            return folders.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            try? await manager.disconnectShare(gracefully: false)
            throw SMBConnectionError.friendly(error)
        }
    }

    private func connect(_ manager: SMB2Manager, share: String) async throws {
        do {
            try await manager.connectShare(name: share, encrypted: false)
        } catch {
            let friendly = SMBConnectionError.friendly(error)
            guard friendly == .authenticationFailed || friendly == .connectionFailed else {
                throw error
            }
            try await manager.connectShare(name: share, encrypted: true)
        }
    }
}
