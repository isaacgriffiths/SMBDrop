import Combine
import Photos
import UIKit

struct PhotoLibraryItem: Identifiable {
    enum Source {
        case asset(PHAsset)
        case sample(SampleContent.Photo)
    }

    let source: Source

    init(asset: PHAsset) {
        source = .asset(asset)
    }

    init(sample: SampleContent.Photo) {
        source = .sample(sample)
    }

    var asset: PHAsset? {
        if case .asset(let asset) = source { return asset }
        return nil
    }

    var id: String {
        switch source {
        case .asset(let asset): asset.localIdentifier
        case .sample(let photo): photo.id
        }
    }

    var isVideo: Bool {
        switch source {
        case .asset(let asset): asset.mediaType == .video
        case .sample(let photo): photo.isVideo
        }
    }

    var durationText: String? {
        guard isVideo else { return nil }
        let duration: Int
        switch source {
        case .asset(let asset): duration = max(0, Int(asset.duration.rounded()))
        case .sample(let photo): duration = photo.durationSeconds
        }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }
}

struct PhotoLibraryAlbum: Identifiable {
    let id: String
    let title: String
    let itemCount: Int
    let previewItems: [PhotoLibraryItem]
    fileprivate let collection: PHAssetCollection?
}

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var albums: [PhotoLibraryAlbum] = []
    @Published private(set) var items: [PhotoLibraryItem] = []
    @Published private(set) var selectedAlbumID: String?
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

    var recentAlbum: PhotoLibraryAlbum? { albums.first }

    var additionalAlbums: [PhotoLibraryAlbum] {
        Array(albums.dropFirst())
    }

    var isShowingAlbums: Bool { selectedAlbumID == nil }

    var selectedAlbumTitle: String {
        albums.first(where: { $0.id == selectedAlbumID })?.title ?? "Photos"
    }

    var selectedItems: [PhotoLibraryItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    /// Re-runs content loading after the Sample Content toggle changes.
    func reloadContent() {
        reload()
    }

    func requestAccess() async {
        if SampleContent.isEnabled {
            reload()
            return
        }
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

    func openAlbum(_ album: PhotoLibraryAlbum) {
        selectedAlbumID = album.id
        if SampleContent.isEnabled {
            let sampleItems = SampleContent.photos.map { PhotoLibraryItem(sample: $0) }
            items = album.id == "sample-videos"
                ? sampleItems.filter(\.isVideo)
                : sampleItems
        } else {
            items = fetchItems(in: album.collection)
        }
        selectedIDs.formIntersection(Set(items.map(\.id)))
    }

    func closeAlbum() {
        selectedAlbumID = nil
        items = []
        clearSelection()
    }

    func setSelectionRange(
        from startID: String,
        to endID: String,
        selecting: Bool,
        baseSelection: Set<String>
    ) {
        guard let start = items.firstIndex(where: { $0.id == startID }),
              let end = items.firstIndex(where: { $0.id == endID }) else {
            return
        }
        var selection = baseSelection
        for item in items[min(start, end)...max(start, end)] {
            if selecting {
                selection.insert(item.id)
            } else {
                selection.remove(item.id)
            }
        }
        selectedIDs = selection
    }

    func thumbnail(for item: PhotoLibraryItem, size: CGSize) async -> UIImage? {
        guard case .asset(let asset) = item.source else {
            if case .sample(let photo) = item.source {
                return SampleContent.image(for: photo, size: size)
            }
            return nil
        }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageManager.requestImage(
                for: asset,
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
        let resources = selection.compactMap(\.asset).flatMap { resourcesToExport(for: $0) }
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
        await transferQueue.startUserInitiatedTransfer()
    }

    private func reload() {
        if SampleContent.isEnabled {
            reloadSampleContent()
            return
        }
        let openAlbumID = selectedAlbumID
        let allAssets = fetchResult(in: nil)
        albums = loadAlbums(allAssets: allAssets)
        if let openAlbumID,
           let openAlbum = albums.first(where: { $0.id == openAlbumID }) {
            selectedAlbumID = openAlbumID
            items = fetchItems(in: openAlbum.collection)
        } else {
            selectedAlbumID = nil
            items = []
        }
        let availableIDs = Set(albums.flatMap { $0.previewItems.map(\.id) } + items.map(\.id))
        selectedIDs.formIntersection(availableIDs)
    }

    private func reloadSampleContent() {
        let sampleItems = SampleContent.photos.map { PhotoLibraryItem(sample: $0) }
        let videoItems = sampleItems.filter(\.isVideo)
        albums = [
            PhotoLibraryAlbum(
                id: "sample-recents",
                title: "Recents",
                itemCount: sampleItems.count,
                previewItems: Array(sampleItems.prefix(4)),
                collection: nil
            ),
            PhotoLibraryAlbum(
                id: "sample-favourites",
                title: "Favourites",
                itemCount: 12,
                previewItems: Array(sampleItems.dropFirst(6).prefix(4)),
                collection: nil
            ),
            PhotoLibraryAlbum(
                id: "sample-videos",
                title: "Videos",
                itemCount: videoItems.count,
                previewItems: Array(videoItems.prefix(4)),
                collection: nil
            ),
        ]
        if let selectedAlbumID, albums.contains(where: { $0.id == selectedAlbumID }) {
            items = selectedAlbumID == "sample-videos" ? videoItems : sampleItems
        } else {
            selectedAlbumID = nil
            items = []
        }
        selectedIDs.formIntersection(Set(sampleItems.map(\.id)))
    }

    private func fetchItems(in collection: PHAssetCollection?) -> [PhotoLibraryItem] {
        let result = fetchResult(in: collection)
        var loaded: [PhotoLibraryItem] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            loaded.append(PhotoLibraryItem(asset: asset))
        }
        return loaded
    }

    private func fetchResult(in collection: PHAssetCollection?) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        return collection.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)
    }

    private func loadAlbums(allAssets: PHFetchResult<PHAsset>) -> [PhotoLibraryAlbum] {
        guard allAssets.count > 0 else { return [] }
        var loaded = [
            PhotoLibraryAlbum(
                id: "smbdrop-recents",
                title: "Recents",
                itemCount: allAssets.count,
                previewItems: previewItems(in: allAssets),
                collection: nil
            )
        ]
        var seenIDs: Set<String> = []
        let smartCollections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        let userCollections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var collections: [PHAssetCollection] = []
        for result in [smartCollections, userCollections] {
            result.enumerateObjects { collection, _, _ in
                guard collection.assetCollectionSubtype != .smartAlbumUserLibrary,
                      collection.assetCollectionSubtype != .smartAlbumRecentlyAdded,
                      seenIDs.insert(collection.localIdentifier).inserted else {
                    return
                }
                collections.append(collection)
            }
        }
        collections.sort { lhs, rhs in
            let left = Self.albumPriority(lhs.assetCollectionSubtype)
            let right = Self.albumPriority(rhs.assetCollectionSubtype)
            if left != right { return left < right }
            return (lhs.localizedTitle ?? "")
                .localizedCaseInsensitiveCompare(rhs.localizedTitle ?? "") == .orderedAscending
        }

        for collection in collections {
            let assets = fetchResult(in: collection)
            guard assets.count > 0 else { continue }
            loaded.append(
                PhotoLibraryAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Album",
                    itemCount: assets.count,
                    previewItems: previewItems(in: assets),
                    collection: collection
                )
            )
        }
        return loaded
    }

    private func previewItems(in result: PHFetchResult<PHAsset>) -> [PhotoLibraryItem] {
        (0..<min(4, result.count)).map {
            PhotoLibraryItem(asset: result.object(at: $0))
        }
    }

    private static func albumPriority(_ subtype: PHAssetCollectionSubtype) -> Int {
        switch subtype {
        case .smartAlbumFavorites: 0
        case .smartAlbumVideos: 1
        case .smartAlbumSelfPortraits: 2
        case .smartAlbumScreenshots: 3
        case .smartAlbumLivePhotos: 4
        case .smartAlbumPanoramas: 5
        default: 100
        }
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
