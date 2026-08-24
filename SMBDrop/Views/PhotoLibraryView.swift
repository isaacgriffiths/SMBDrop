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

    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 180), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch library.authorizationStatus {
                case .authorized, .limited:
                    if library.items.isEmpty {
                        ContentUnavailableView(
                            "No Photos or Videos",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Your photo library is empty.")
                        )
                    } else {
                        photoGrid
                    }
                case .notDetermined:
                    ProgressView("Opening your photo library…")
                case .denied, .restricted:
                    ContentUnavailableView {
                        Label("Photo Access Needed", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Allow photo-library access in Settings to browse and send photos and videos.")
                    } actions: {
                        Button("Open Settings") { openSystemSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                @unknown default:
                    ContentUnavailableView("Photos Unavailable", systemImage: "photo")
                }
            }
            .navigationTitle("Photos")
            .toolbar {
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

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.items) { item in
                    PhotoGridCell(
                        item: item,
                        isSelected: library.selectedIDs.contains(item.id),
                        showsSelection: isSelecting,
                        thumbnail: { size in
                            await library.thumbnail(for: item, size: size)
                        }
                    )
                    .onTapGesture {
                        if !isSelecting { isSelecting = true }
                        library.toggle(item)
                    }
                    .accessibilityLabel(item.isVideo ? "Video" : "Photo")
                    .accessibilityValue(
                        library.selectedIDs.contains(item.id) ? "Selected" : "Not selected"
                    )
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
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
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(Color.white, lineWidth: 3)
                }

                if showsSelection {
                    VStack {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.25))
                                Circle().stroke(Color.white, lineWidth: 2)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 26, height: 26)
                            .padding(7)
                        }
                        Spacer()
                    }
                }

                if let duration = item.durationText {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                            Text(duration)
                                .monospacedDigit()
                            Spacer()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
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
}
