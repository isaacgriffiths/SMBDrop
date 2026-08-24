import Foundation
import Network

protocol TCPConnectionProbing {
    func connect(host: String, port: UInt16) async throws
}

struct TCPConnectionProbe: TCPConnectionProbing {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    func connect(host: String, port: UInt16) async throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw SMBConnectionError.invalidServer
        }

        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.isaacgriffiths.smbdrop.tcp-probe")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: networkPort,
                using: .tcp
            )
            let state = TCPProbeState(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { networkState in
                switch networkState {
                case .ready:
                    state.finish(.success(()))
                case .waiting(let error), .failed(let error):
                    if let mapped = Self.immediateError(for: error) {
                        state.finish(.failure(mapped))
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                state.finish(.failure(SMBConnectionError.tcpTimedOut))
            }
        }
    }

    private static func immediateError(for error: NWError) -> SMBConnectionError? {
        guard case .posix(let code) = error else { return nil }
        switch code {
        case .EPERM, .EACCES:
            return .localNetworkDenied
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH:
            return .serverUnavailable
        default:
            return nil
        }
    }
}

private final class TCPProbeState: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, any Error>
    private let lock = NSLock()
    private var isFinished = false

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
