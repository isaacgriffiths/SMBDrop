import Combine
import Photos
import UIKit

struct PhotoLibraryItem: Identifiable {
    let asset: PHAsset

    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }

    var durationText: String? {
        guard isVideo else { return nil }
        let duration = max(0, Int(asset.duration.rounded()))
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }
}

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var items: [PhotoLibraryItem] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isPreparing = false
    @Published private(set) var preparedCount = 0
    @Published private(set) var resourceCount = 0

    private let imageManager = PHCachingImageManager()

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        PHPhotoLibrary.shared().register(self)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            reload()
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    @objc nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.reload()
        }
    }

    var selectedCount: Int { selectedIDs.count }

    var selectedItems: [PhotoLibraryItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func requestAccess() async {
        if authorizationStatus == .notDetermined {
            authorizationStatus = await withCheckedContinuation {
                (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        }
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            reload()
        }
    }

    func toggle(_ item: PhotoLibraryItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func clearSelection() {
        selectedIDs = []
    }

    func thumbnail(for item: PhotoLibraryItem, size: CGSize) async -> UIImage? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageManager.requestImage(
                for: item.asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: image)
            }
        }
    }

    func enqueueSelection(
        to destination: DestinationSummary,
        transferQueue: TransferQueueViewModel
    ) async throws {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        isPreparing = true
        preparedCount = 0
        let resources = selection.flatMap { resourcesToExport(for: $0.asset) }
        resourceCount = resources.count
        let batchID = UUID()
        transferQueue.track(batchID: batchID)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBDrop-Photos-\(batchID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            isPreparing = false
        }

        for (asset, resource) in resources {
            let localURL = directoryURL.appendingPathComponent(UUID().uuidString)
            try await write(resource, to: localURL)
            if let date = asset.creationDate {
                try? FileManager.default.setAttributes(
                    [.creationDate: date, .modificationDate: date],
                    ofItemAtPath: localURL.path
                )
            }
            _ = try await transferQueue.enqueueFile(
                at: localURL,
                filename: resource.originalFilename,
                destinationID: destination.id,
                batchID: batchID,
                moveSource: true
            )
            preparedCount += 1
        }

        clearSelection()
        await transferQueue.resume()
    }

    private func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var loaded: [PhotoLibraryItem] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            loaded.append(PhotoLibraryItem(asset: asset))
        }
        items = loaded
        selectedIDs.formIntersection(Set(loaded.map(\.id)))
    }

    private func resourcesToExport(for asset: PHAsset) -> [(PHAsset, PHAssetResource)] {
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
            return selected.map { (asset, $0) }
        case .video:
            let video = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
            return video.map { [(asset, $0)] } ?? []
        default:
            return []
        }
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
