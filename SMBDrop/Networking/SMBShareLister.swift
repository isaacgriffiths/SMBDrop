import AMSMB2
import Foundation

protocol DestinationShareListing {
    func availableShares(host: String, username: String, password: String) async throws -> [String]
}

// Lists the disk shares a server exposes so users can tap one instead of
// typing a share name, mirroring PhotoSync and the Files app.
struct SMBShareLister: DestinationShareListing {
    private let tcpProbe: any TCPConnectionProbing

    init(tcpProbe: any TCPConnectionProbing = TCPConnectionProbe()) {
        self.tcpProbe = tcpProbe
    }

    func availableShares(host: String, username: String, password: String) async throws -> [String] {
        let host = try Destination.validatedHost(host)
        try await tcpProbe.connect(host: host, port: 445)

        let credential = URLCredential(
            user: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            persistence: .forSession
        )
        guard
            let url = URL(string: "smb://\(host)"),
            let manager = SMB2Manager(url: url, credential: credential)
        else {
            throw SMBConnectionError.invalidServer
        }
        manager.timeout = 15

        do {
            // enumerateHidden stays off so IPC$, print$ and friends are excluded.
            return try await manager.listShares()
                .map { $0.name }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            throw SMBConnectionError.friendly(error)
        }
    }
}
