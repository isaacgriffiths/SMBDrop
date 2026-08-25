import Photos
import SwiftUI
import UIKit

struct PhotoLibraryView: View {
    let destinations: [DestinationSummary]
    @ObservedObject var transferQueue: TransferQueueViewModel
    @Binding var selectedTab: SMBDropTab
    @StateObject private var library = PhotoLibraryViewModel()
    @State private var isSelecting = false
    @State private var isChoosingDestination = false
    @State private var exportError: String?
    @State private var photoFrames: [String: CGRect] = [:]
    @State private var dragStartID: String?
    @State private var dragBaseSelection: Set<String> = []
    @State private var dragSelects = true

    private let albumColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]
    private let photoColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch library.authorizationStatus {
                case .authorized, .limited:
                    if library.albums.isEmpty {
                        ContentUnavailableView(
                            "No Photos or Videos",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Your photo library is empty.")
                        )
                    } else if library.isShowingAlbums {
                        albumBrowser
                    } else {
                        photoGrid
                    }
                case .notDetermined:
                    ProgressView("Opening your photo library…")
                case .denied, .restricted:
                    ContentUnavailableView {
                        Label("Photo Access Needed", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Allow photo-library access in Settings to browse albums and send photos and videos.")
                    } actions: {
                        Button("Open Settings") { openSystemSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                @unknown default:
                    ContentUnavailableView("Photos Unavailable", systemImage: "photo")
                }
            }
            .navigationTitle(library.isShowingAlbums ? "Photos" : library.selectedAlbumTitle)
            .navigationBarTitleDisplayMode(library.isShowingAlbums ? .large : .inline)
            .toolbar { photoToolbar }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .sheet(isPresented: $isChoosingDestination) {
                DestinationPickerSheet(
                    destinations: destinations,
                    itemCount: library.selectedCount
                ) { destination in
                    Task { await sendSelection(to: destination) }
                }
            }
            .alert(
                "Could Not Send Photos",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "Unknown error")
            }
            .task {
                await library.requestAccess()
            }
        }
    }

    private var albumBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let recentAlbum = library.recentAlbum {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recents", count: recentAlbum.itemCount)
                        Button {
                            openAlbum(recentAlbum)
                        } label: {
                            RecentAlbumPreview(
                                album: recentAlbum,
                                thumbnail: { item, size in
                                    await library.thumbnail(for: item, size: size)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recents, \(recentAlbum.itemCount) items")
                    }
                }

                if !library.additionalAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Albums")
                            .font(.title2.bold())
                        LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 22) {
                            ForEach(library.additionalAlbums) { album in
                                Button {
                                    openAlbum(album)
                                } label: {
                                    AlbumPreview(
                                        album: album,
                                        thumbnail: { item, size in
                                            await library.thumbnail(for: item, size: size)
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(album.title), \(album.itemCount) items")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
            Spacer()
            Text("\(count.formatted()) items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: photoColumns, spacing: 1) {
                ForEach(library.items) { item in
                    PhotoGridCell(
                        item: item,
                        isSelected: library.selectedIDs.contains(item.id),
                        showsSelection: isSelecting,
                        thumbnail: { size in
                            await library.thumbnail(for: item, size: size)
                        }
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PhotoFramePreferenceKey.self,
                                value: [
                                    item.id: proxy.frame(in: .named("SMBDropPhotoGrid")),
                                ]
                            )
                        }
                    }
                    .onTapGesture {
                        if !isSelecting { isSelecting = true }
                        library.toggle(item)
                    }
                    .accessibilityLabel(item.isVideo ? "Video" : "Photo")
                    .accessibilityValue(
                        library.selectedIDs.contains(item.id) ? "Selected" : "Not selected"
                    )
                    .accessibilityHint("Double tap to toggle selection")
                }
            }
        }
        .coordinateSpace(name: "SMBDropPhotoGrid")
        .onPreferenceChange(PhotoFramePreferenceKey.self) { photoFrames = $0 }
        .simultaneousGesture(dragSelectionGesture)
        .background(Color(uiColor: .systemBackground))
    }

    private var dragSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("SMBDropPhotoGrid"))
            .onChanged { value in
                guard isSelecting,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 10 else {
                    return
                }
                if dragStartID == nil {
                    guard let startID = photoID(at: value.startLocation) else { return }
                    dragStartID = startID
                    dragBaseSelection = library.selectedIDs
                    dragSelects = !dragBaseSelection.contains(startID)
                }
                guard let dragStartID,
                      let endID = photoID(at: value.location) else {
                    return
                }
                library.setSelectionRange(
                    from: dragStartID,
                    to: endID,
                    selecting: dragSelects,
                    baseSelection: dragBaseSelection
                )
            }
            .onEnded { _ in
                dragStartID = nil
                dragBaseSelection = []
            }
    }

    private func photoID(at point: CGPoint) -> String? {
        photoFrames.first(where: { $0.value.contains(point) })?.key
    }

    @ToolbarContentBuilder
    private var photoToolbar: some ToolbarContent {
        if !library.isShowingAlbums {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isSelecting = false
                    library.closeAlbum()
                } label: {
                    Label("Albums", systemImage: "chevron.left")
                }
                .disabled(library.isPreparing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Cancel" : "Select") {
                    if isSelecting {
                        library.clearSelection()
                    }
                    isSelecting.toggle()
                }
                .disabled(library.items.isEmpty || library.isPreparing)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if library.selectedCount > 0 || transferQueue.activeProgress != nil {
            VStack(spacing: 10) {
                if transferQueue.activeProgress != nil {
                    TransferActivityView(transferQueue: transferQueue)
                }
                if library.isPreparing {
                    ProgressView(
                        "Preparing \(min(library.preparedCount + 1, max(1, library.resourceCount))) of \(library.resourceCount)…",
                        value: Double(library.preparedCount),
                        total: Double(max(1, library.resourceCount))
                    )
                } else if library.selectedCount > 0 {
                    Button {
                        if destinations.isEmpty {
                            selectedTab = .settings
                        } else {
                            isChoosingDestination = true
                        }
                    } label: {
                        Label(
                            "Send \(library.selectedCount) Item\(library.selectedCount == 1 ? "" : "s")",
                            systemImage: "arrow.up.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private func openAlbum(_ album: PhotoLibraryAlbum) {
        isSelecting = false
        library.clearSelection()
        library.openAlbum(album)
    }

    private func sendSelection(to destination: DestinationSummary) async {
        do {
            try await library.enqueueSelection(
                to: destination,
                transferQueue: transferQueue
            )
            isSelecting = false
        } catch {
            exportError = error.localizedDescription
            await transferQueue.resume()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct RecentAlbumPreview: View {
    let album: PhotoLibraryAlbum
    let thumbnail: (PhotoLibraryItem, CGSize) async -> UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        Group {
                            if album.previewItems.indices.contains(index) {
                                PhotoPreview(
                                    item: album.previewItems[index],
                                    thumbnail: thumbnail
                                )
                            } else {
                                Color(uiColor: .secondarySystemBackground)
                            }
                        }
                        .frame(width: max(0, (proxy.size.width - 6) / 4))
                    }
                }
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("View all photos and videos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlbumPreview: View {
    let album: PhotoLibraryAlbum
    let thumbnail: (PhotoLibraryItem, CGSize) async -> UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                let tileWidth = max(0, (proxy.size.width - 2) / 2)
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(tileWidth), spacing: 2),
                        GridItem(.fixed(tileWidth), spacing: 2),
                    ],
                    spacing: 2
                ) {
                    ForEach(0..<4, id: \.self) { index in
                        Group {
                            if album.previewItems.indices.contains(index) {
                                PhotoPreview(
                                    item: album.previewItems[index],
                                    thumbnail: thumbnail
                                )
                            } else {
                                Color(uiColor: .secondarySystemBackground)
                            }
                        }
                        .frame(width: tileWidth, height: tileWidth)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(album.itemCount.formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PhotoPreview: View {
    let item: PhotoLibraryItem
    let thumbnail: (PhotoLibraryItem, CGSize) async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if let duration = item.durationText {
                    VStack {
                        HStack {
                            Spacer()
                            VideoDurationBadge(duration: duration)
                                .padding(4)
                        }
                        Spacer()
                    }
                }
            }
            .clipped()
            .task(id: item.id) {
                let scale = UIScreen.main.scale
                image = await thumbnail(
                    item,
                    CGSize(width: proxy.size.width * scale, height: proxy.size.height * scale)
                )
            }
        }
    }
}

private struct PhotoGridCell: View {
    let item: PhotoLibraryItem
    let isSelected: Bool
    let showsSelection: Bool
    let thumbnail: (CGSize) async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }

                if isSelected {
                    Color.accentColor.opacity(0.12)
                    Rectangle()
                        .stroke(Color.white, lineWidth: 3)
                }

                VStack {
                    HStack(alignment: .top) {
                        if showsSelection {
                            selectionCircle
                        }
                        Spacer()
                        if let duration = item.durationText {
                            VideoDurationBadge(duration: duration)
                        }
                    }
                    .padding(6)
                    Spacer()
                }
            }
            .clipped()
            .task(id: item.id) {
                let scale = UIScreen.main.scale
                image = await thumbnail(
                    CGSize(width: proxy.size.width * scale, height: proxy.size.height * scale)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var selectionCircle: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.black.opacity(0.32))
            Circle()
                .stroke(Color.white, lineWidth: 2)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 25, height: 25)
    }

}

private struct VideoDurationBadge: View {
    let duration: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "video.fill")
                .font(.system(size: 8, weight: .bold))
            Text(duration)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.68), in: Capsule())
    }
}

private struct PhotoFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
