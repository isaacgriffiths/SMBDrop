import QuickLook
import SwiftUI

struct SMBImportView: View {
    let destinations: [DestinationSummary]
    @Binding var selectedTab: SMBDropTab
    @StateObject private var viewModel = SMBImportViewModel()
    @StateObject private var localImports = ImportedFileLibrary()
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty && localImports.items.isEmpty {
                    noDestinationsView
                } else if viewModel.destinationID == nil {
                    destinationsView
                } else {
                    directoryView
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                importBar
            }
            .alert(
                "Could Not Import",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .alert(
                "Import Library",
                isPresented: Binding(
                    get: { localImports.errorMessage != nil },
                    set: { if !$0 { localImports.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { localImports.errorMessage = nil }
            } message: {
                Text(localImports.errorMessage ?? "Unknown error")
            }
            .alert(
                "Saved to Photos",
                isPresented: Binding(
                    get: { localImports.confirmationMessage != nil },
                    set: { if !$0 { localImports.clearConfirmation() } }
                )
            ) {
                Button("OK", role: .cancel) { localImports.clearConfirmation() }
            } message: {
                Text(localImports.confirmationMessage ?? "")
            }
            .quickLookPreview($previewURL)
            .task { localImports.reload() }
        }
    }

    private var navigationTitle: String {
        guard let destinationID = viewModel.destinationID,
              let destination = destinations.first(where: { $0.id == destinationID }) else {
            return "Import"
        }
        guard !viewModel.currentPath.isEmpty else { return destination.displayName }
        return viewModel.currentPath.split(separator: "/").last.map(String.init)
            ?? destination.displayName
    }

    private var noDestinationsView: some View {
        ContentUnavailableView {
            Label("No SMB Shares", systemImage: "externaldrive.badge.plus")
        } description: {
            Text("Connect an SMB share in Settings, then come back here to import files from it.")
        } actions: {
            Button("Open Settings") {
                selectedTab = .settings
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var destinationsView: some View {
        List {
            Section {
                if localImports.items.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No imports yet")
                                .foregroundStyle(.primary)
                            Text("Files you import from an SMB share will stay available here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !localImports.mediaItems.isEmpty {
                        importedMediaCarousel
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    ForEach(localImports.documentItems) { item in
                        importedDocumentRow(item)
                    }
                }
            } header: {
                HStack {
                    Text("On This iPhone")
                    Spacer()
                    if !localImports.items.isEmpty {
                        Text("\(localImports.items.count)")
                    }
                }
            } footer: {
                if !localImports.items.isEmpty {
                    Text("Tap an item to preview it. Use its menu to share it or add compatible media to Photos.")
                }
            }

            Section {
                if destinations.isEmpty {
                    Button {
                        selectedTab = .settings
                    } label: {
                        Label("Connect an SMB Share", systemImage: "externaldrive.badge.plus")
                    }
                } else {
                    ForEach(destinations) { destination in
                        Button {
                            Task { await viewModel.openDestination(destination.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "externaldrive.connected.to.line.below.fill")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 42, height: 42)
                                    .background(
                                        Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 11)
                                    )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(destination.displayPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } header: {
                Text("Connected Shares")
            } footer: {
                Text("Choose a share to browse and import more files.")
            }
        }
    }

    private var importedMediaCarousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(localImports.mediaItems) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Button {
                            previewURL = item.url
                        } label: {
                            ImportedFileThumbnail(
                                item: item,
                                size: CGSize(width: 144, height: 112)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                if item.kind == .video {
                                    Image(systemName: "video.fill")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.black.opacity(0.65), in: Capsule())
                                        .padding(7)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 5) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            importedFileMenu(item)
                        }
                    }
                    .frame(width: 144)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func importedDocumentRow(_ item: ImportedFile) -> some View {
        HStack(spacing: 12) {
            Button {
                previewURL = item.url
            } label: {
                HStack(spacing: 12) {
                    ImportedFileThumbnail(
                        item: item,
                        size: CGSize(width: 44, height: 52)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            importedFileMenu(item)
        }
    }

    private func importedFileMenu(_ item: ImportedFile) -> some View {
        Menu {
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if item.canSaveToPhotos {
                Button {
                    Task { await localImports.saveToPhotos(item) }
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(item.name)")
    }

    private var directoryView: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading folder…")
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("There are no files or folders here.")
                )
            } else {
                List(viewModel.items) { item in
                    Button {
                        if item.isDirectory {
                            Task { await viewModel.openFolder(item) }
                        } else {
                            viewModel.toggle(item)
                        }
                    } label: {
                        remoteItemRow(item)
                    }
                    .disabled(viewModel.isImporting)
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
    }

    private func remoteItemRow(_ item: SMBRemoteItem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbolName(for: item))
                .font(.title2)
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.isDirectory {
                    Text(detail(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            } else {
                Image(
                    systemName: viewModel.selectedIDs.contains(item.id)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                    viewModel.selectedIDs.contains(item.id) ? Color.accentColor : .secondary
                )
            }
        }
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.destinationID != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if viewModel.canBrowseToParent {
                        Task { await viewModel.browseToParent() }
                    } else {
                        viewModel.closeDestination()
                    }
                } label: {
                    Label(
                        viewModel.canBrowseToParent ? "Back" : "Shares",
                        systemImage: "chevron.left"
                    )
                }
                .disabled(viewModel.isImporting)
            }
            if viewModel.selectedCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { viewModel.clearSelection() }
                        .disabled(viewModel.isImporting)
                }
            }
        }
    }

    @ViewBuilder
    private var importBar: some View {
        if let progress = viewModel.importProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Importing \(progress.filename)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(min(progress.completedItemCount + 1, progress.totalItemCount)) of \(progress.totalItemCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(
                    value: Double(progress.bytesTransferred),
                    total: Double(max(1, progress.totalBytes ?? progress.bytesTransferred))
                )
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        } else if viewModel.selectedCount > 0 {
            Button {
                Task {
                    await viewModel.importSelection()
                    localImports.reload()
                }
            } label: {
                Label(
                    "Import \(viewModel.selectedCount) Item\(viewModel.selectedCount == 1 ? "" : "s")",
                    systemImage: "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        } else if !viewModel.importedURLs.isEmpty {
            VStack(spacing: 6) {
                Label(
                    "Imported \(viewModel.importedURLs.count) Item\(viewModel.importedURLs.count == 1 ? "" : "s")",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                Text("Saved in Files › On My iPhone › SMBDrop › SMBDrop Imports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("View Imports") {
                    localImports.reload()
                    viewModel.closeDestination()
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private func symbolName(for item: SMBRemoteItem) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.name.split(separator: ".").last?.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff":
            return "photo.fill"
        case "mov", "mp4", "m4v", "avi", "mkv":
            return "video.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "tar", "gz", "7z":
            return "archivebox.fill"
        default:
            return "doc.fill"
        }
    }

    private func detail(for item: SMBRemoteItem) -> String {
        var details: [String] = []
        if let byteCount = item.byteCount {
            details.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        }
        if let modificationDate = item.modificationDate {
            details.append(modificationDate.formatted(date: .abbreviated, time: .shortened))
        }
        return details.joined(separator: " · ")
    }
}
