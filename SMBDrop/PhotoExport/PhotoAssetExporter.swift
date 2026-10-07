import Foundation
import Photos

/// Copies a library asset's original resources out of Photos, unchanged:
/// the original photo, any RAW/alternate, and a Live Photo's paired video.
struct PhotoAssetExporter {
    struct StagedResource {
        let fileURL: URL
        let filename: String
    }

    func resources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            var selected: [PHAssetResource] = []
            if let photo = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto }) {
                selected.append(photo)
            }
            selected.append(contentsOf: resources.filter { $0.type == .alternatePhoto })
            if asset.mediaSubtypes.contains(.photoLive),
               let pairedVideo = resources.first(where: { $0.type == .pairedVideo })
                ?? resources.first(where: { $0.type == .fullSizePairedVideo }) {
                selected.append(pairedVideo)
            }
            return selected
        case .video:
            let video = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
            return video.map { [$0] } ?? []
        default:
            return []
        }
    }

    /// Writes every resource of one asset into `directoryURL`. Either all of
    /// them land or none do, so a Live Photo never goes out half-sent.
    func stage(_ asset: PHAsset, in directoryURL: URL) async throws -> [StagedResource] {
        let resources = resources(for: asset)
        guard !resources.isEmpty else { throw PhotoExportError.noOriginalResource }
        var staged: [StagedResource] = []
        do {
            for resource in resources {
                let fileURL = directoryURL.appendingPathComponent(UUID().uuidString)
                try await write(resource, to: fileURL)
                staged.append(StagedResource(fileURL: fileURL, filename: resource.originalFilename))
                if let date = asset.creationDate {
                    try? FileManager.default.setAttributes(
                        [.creationDate: date, .modificationDate: date],
                        ofItemAtPath: fileURL.path
                    )
                }
            }
        } catch {
            for resource in staged {
                try? FileManager.default.removeItem(at: resource.fileURL)
            }
            throw error
        }
        return staged
    }

    private func write(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum PhotoExportError: LocalizedError {
    case noOriginalResource

    var errorDescription: String? {
        switch self {
        case .noOriginalResource:
            "Photos did not provide an original file for this item."
        }
    }
}
