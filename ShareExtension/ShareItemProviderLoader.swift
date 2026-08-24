import Foundation
import UniformTypeIdentifiers

struct LoadedShareItem {
    let temporaryURL: URL
    let filename: String
}

struct ShareItemProviderLoader {
    func load(_ provider: NSItemProvider) async throws -> LoadedShareItem {
        guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
            throw ShareItemLoadingError.unsupportedItem
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareItemLoadingError.fileUnavailable }

                    let filename = Self.filename(
                        suggestedName: provider.suggestedName,
                        sourceURL: url,
                        typeIdentifier: typeIdentifier
                    )
                    let temporaryDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: temporaryDirectory,
                        withIntermediateDirectories: false
                    )
                    let temporaryURL = temporaryDirectory.appendingPathComponent(
                        filename,
                        isDirectory: false
                    )
                    do {
                        try FileManager.default.copyItem(at: url, to: temporaryURL)
                        continuation.resume(
                            returning: LoadedShareItem(
                                temporaryURL: temporaryURL,
                                filename: filename
                            )
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: temporaryDirectory)
                        throw error
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let identifiers = provider.registeredTypeIdentifiers
        let supportedTypes: [UTType] = [.movie, .image, .fileURL, .data]
        for supportedType in supportedTypes {
            if let identifier = identifiers.first(where: {
                UTType($0)?.conforms(to: supportedType) == true
            }) {
                return identifier
            }
        }
        return identifiers.first
    }

    private static func filename(
        suggestedName: String?,
        sourceURL: URL,
        typeIdentifier: String
    ) -> String {
        var name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name == "." || name == ".." {
            name = sourceURL.lastPathComponent
        }
        name = URL(fileURLWithPath: name).lastPathComponent

        if (name as NSString).pathExtension.isEmpty,
           let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension {
            name += ".\(fileExtension)"
        }
        if name.isEmpty || name == "." || name == ".." {
            name = "Shared Item"
        }
        return name
    }
}

enum ShareItemLoadingError: LocalizedError {
    case fileUnavailable
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .fileUnavailable:
            return "Photos did not provide a readable file for this item."
        case .unsupportedItem:
            return "That item cannot be shared as a photo, video, or file."
        }
    }
}
