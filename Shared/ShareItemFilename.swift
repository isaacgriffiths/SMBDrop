import Foundation
import UniformTypeIdentifiers

enum ShareItemFilename {
    static func resolve(
        suggestedName: String?,
        sourceURL: URL,
        typeIdentifier: String
    ) throws -> String {
        for candidate in [suggestedName, sourceURL.lastPathComponent].compactMap({ $0 }) {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsable(trimmedCandidate) else { continue }
            let name = URL(fileURLWithPath: trimmedCandidate).lastPathComponent
            guard isUsable(name), !isPhotosTemporaryCopyName(name) else { continue }
            return addingPreferredExtension(
                to: name,
                sourceURL: sourceURL,
                typeIdentifier: typeIdentifier
            )
        }

        throw ShareItemFilenameError.originalFilenameUnavailable
    }

    private static func addingPreferredExtension(
        to name: String,
        sourceURL: URL,
        typeIdentifier: String
    ) -> String {
        guard (name as NSString).pathExtension.isEmpty else {
            return name
        }

        let sourceExtension = sourceURL.pathExtension
        if !sourceExtension.isEmpty {
            return "\(name).\(sourceExtension)"
        }
        guard let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension else {
            return name
        }
        return "\(name).\(fileExtension)"
    }

    private static func isUsable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
    }

    private static func isPhotosTemporaryCopyName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        guard stem.lowercased().hasPrefix("copy_") else { return false }
        return UUID(uuidString: String(stem.dropFirst("copy_".count))) != nil
    }
}

enum ShareItemFilenameError: LocalizedError, Equatable {
    case originalFilenameUnavailable

    var errorDescription: String? {
        "Photos did not provide the original filename. In Photos, open Options, choose Current format, and share the item again."
    }
}
