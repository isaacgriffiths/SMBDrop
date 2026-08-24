import Foundation
import UniformTypeIdentifiers

struct ShareItemProviderLoader {
    func load(_ provider: NSItemProvider) async throws -> LoadedShareItem {
        guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
            throw ShareItemLoadingError.unsupportedItem
        }

        do {
            return try await loadInPlace(
                provider,
                typeIdentifier: typeIdentifier
            )
        } catch {
            return try await loadCopiedRepresentation(
                provider,
                typeIdentifier: typeIdentifier
            )
        }
    }

    private func loadInPlace(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> LoadedShareItem {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) {
                url,
                _,
                error in
                Self.finishLoading(
                    sourceURL: url,
                    error: error,
                    suggestedName: provider.suggestedName,
                    typeIdentifier: typeIdentifier,
                    continuation: continuation
                )
            }
        }
    }

    private func loadCopiedRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> LoadedShareItem {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                Self.finishLoading(
                    sourceURL: url,
                    error: error,
                    suggestedName: provider.suggestedName,
                    typeIdentifier: typeIdentifier,
                    continuation: continuation
                )
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

    private static func finishLoading(
        sourceURL: URL?,
        error: Error?,
        suggestedName: String?,
        typeIdentifier: String,
        continuation: CheckedContinuation<LoadedShareItem, Error>
    ) {
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let sourceURL else {
            continuation.resume(throwing: ShareItemLoadingError.fileUnavailable)
            return
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<LoadedShareItem, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try ShareItemFileStager.stage(
                    sourceURL: coordinatedURL,
                    suggestedName: suggestedName,
                    typeIdentifier: typeIdentifier
                )
            }
        }

        if let result {
            continuation.resume(with: result)
        } else {
            continuation.resume(
                throwing: coordinationError ?? ShareItemLoadingError.fileUnavailable
            )
        }
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
