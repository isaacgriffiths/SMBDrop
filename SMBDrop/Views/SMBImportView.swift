import StoreKit
import SwiftUI

struct SMBImportView: View {
    let destinations: [DestinationSummary]
    @Binding var selectedTab: SMBDropTab
    @StateObject private var viewModel = SMBImportViewModel()
    @Environment(\.requestReview) private var requestReview
    @AppStorage("hasRequestedReview") private var hasRequestedReview = false
    @AppStorage(SampleContent.defaultsKey) private var isSampleContentOn = false

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty {
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
            .onChange(of: viewModel.importedURLs) {
                requestReviewAfterFirstImport()
            }
        }
    }

    /// The user's first successful import is the moment the app has proven
    /// itself, so that is when the one-time system rating panel appears.
    private func requestReviewAfterFirstImport() {
        guard !viewModel.importedURLs.isEmpty,
              !hasRequestedReview,
              !isSampleContentOn else { return }
        hasRequestedReview = true
        Task {
            // Let the "Imported" confirmation land before asking.
            try? await Task.sleep(for: .seconds(1.5))
            requestReview()
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
            } header: {
                Text("Connected Shares")
            } footer: {
                Text("Choose a share, browse its folders, then select files to save on this iPhone. Imported files appear in the Files tab.")
            }
        }
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
                Task { await viewModel.importSelection() }
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
                Button("View in Files") {
                    viewModel.closeDestination()
                    selectedTab = .files
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
