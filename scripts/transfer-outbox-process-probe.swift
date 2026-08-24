import Foundation

@main
struct TransferOutboxProcessProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw ProbeError.invalidArguments
        }

        let action = arguments[1]
        let rootURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let outbox = TransferOutbox(rootURL: rootURL)

        switch action {
        case "enqueue":
            guard arguments.count == 5 else {
                throw ProbeError.invalidArguments
            }
            let sourceURL = URL(fileURLWithPath: arguments[3], isDirectory: false)
            let transfer = try await outbox.enqueueFile(at: sourceURL, filename: arguments[4])
            print(transfer.id.uuidString)
        case "claim":
            guard arguments.count == 3 else {
                throw ProbeError.invalidArguments
            }
            let work = try await outbox.claimNext()
            print(work?.transfer.id.uuidString ?? "none")
        default:
            throw ProbeError.invalidArguments
        }
    }

    private enum ProbeError: LocalizedError {
        case invalidArguments

        var errorDescription: String? {
            "Use enqueue <root> <source> <filename> or claim <root>."
        }
    }
}
