import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FilesBrowserView: View {
    let destinations: [DestinationSummary]
    @ObservedObject var transferQueue: TransferQueueViewModel
    @Binding var selectedTab: SMBDropTab
    @State private var files: [SelectedFile] = []
    @State private var isShowingImporter = false
    @State private var isChoosingDestination = false
    @State private var isPreparing = false
    @State private var preparedCount = 0
    @State private var exportError: String?
    @State private var previewURL: URL?
    @StateObject private var localImports = ImportedFileLibrary()
    @AppStorage(SampleContent.defaultsKey) private var isSampleContentOn = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty && localImports.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Files Yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Choose files from iCloud Drive, On My iPhone, or another provider to send them to an SMB share. Imports will also appear here.")
                    } actions: {
                        Button("Choose Files to Send") {
                            isShowingImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            Button {
                                isShowingImporter = true
                            } label: {
                                Label("Choose Files to Send", systemImage: "folder.badge.plus")
                            }
                            .disabled(isPreparing)
                            ForEach(externalFiles) { file in
                                selectedFileRow(file)
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { externalFiles[$0].id }
                                files.removeAll { ids.contains($0.id) }
                            }
                        } header: {
                            Text("Send to a Share")
                        } footer: {
                            Text("Opens Apple’s secure file picker for iCloud Drive, On My iPhone, and third-party providers.")
                        }

                        if !localImports.items.isEmpty {
                            Section {
                                ForEach(localImports.items) { item in
                                    importedFileRow(item)
                                }
                            } header: {
                                HStack {
                                    Text("On This iPhone")
                                    Spacer()
                                    Text("\(localImports.items.count)")
                                }
                            } footer: {
                                Text("Files imported from your SMB shares. Tap to select for sending; use the menu to preview, share, save to Photos, or delete.")
                            }
                        }

                        if isPreparing {
                            Section {
                                ProgressView(
                                    "Preparing \(preparedCount + 1) of \(files.count)…",
                                    value: Double(preparedCount),
                                    total: Double(max(1, files.count))
                                )
                            }
                        }

                    }
                }
            }
            .navigationTitle("Files")
            .task { localImports.reload() }
            .onChange(of: isSampleContentOn) {
                files = []
                localImports.reload()
            }
            .safeAreaInset(edge: .bottom) {
                if transferQueue.activeProgress != nil || !files.isEmpty {
                    VStack(spacing: 10) {
                        if transferQueue.activeProgress != nil {
                            TransferActivityView(transferQueue: transferQueue)
                        }
                        if !files.isEmpty {
                            Button {
                                if destinations.isEmpty {
                                    selectedTab = .settings
                                } else {
                                    isChoosingDestination = true
                                }
                            } label: {
                                Label(
                                    "Send \(files.count) Item\(files.count == 1 ? "" : "s")",
                                    systemImage: "arrow.up.circle.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPreparing)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    appendFiles(urls)
                case .failure(let error):
                    exportError = error.localizedDescription
                }
            }
            .sheet(isPresented: $isChoosingDestination) {
                DestinationPickerSheet(
                    destinations: destinations,
                    itemCount: files.count
                ) { destination in
                    Task { await sendFiles(to: destination) }
                }
            }
            .alert(
                "Could Not Send Files",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "Unknown error")
            }
            .alert(
                "Imported Files",
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
        }
    }

    private func importedFileRow(_ item: ImportedFile) -> some View {
        HStack(spacing: 12) {
            Button {
                toggleFile(item.url)
            } label: {
                HStack(spacing: 12) {
                    ImportedFileThumbnail(
                        item: item,
                        size: CGSize(width: 42, height: 48)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(
                        systemName: isSelected(item.url)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .foregroundStyle(
                        isSelected(item.url) ? Color.accentColor : .secondary
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            importedFileMenu(item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                deleteImportedFile(item)
            }
        }
    }

    private func importedFileMenu(_ item: ImportedFile) -> some View {
        Menu {
            Button {
                previewURL = item.url
            } label: {
                Label("Preview", systemImage: "eye")
            }
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
            Button(role: .destructive) {
                deleteImportedFile(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(item.name)")
    }

    private func deleteImportedFile(_ item: ImportedFile) {
        localImports.delete(item)
        files.removeAll { $0.url.standardizedFileURL == item.url.standardizedFileURL }
    }

    private func appendFiles(_ urls: [URL]) {
        var existing = Set(files.map { $0.url.standardizedFileURL })
        for url in urls where existing.insert(url.standardizedFileURL).inserted {
            files.append(SelectedFile(url: url))
        }
    }

    private var externalFiles: [SelectedFile] {
        let localURLs = Set(localImports.items.map { $0.url.standardizedFileURL })
        return files.filter { !localURLs.contains($0.url.standardizedFileURL) }
    }

    private func isSelected(_ url: URL) -> Bool {
        files.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private func toggleFile(_ url: URL) {
        if let index = files.firstIndex(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) {
            files.remove(at: index)
        } else {
            files.append(SelectedFile(url: url))
        }
    }

    private func selectedFileRow(_ file: SelectedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .lineLimit(1)
                Text(file.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                files.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(file.name)")
        }
    }

    private func sendFiles(to destination: DestinationSummary) async {
        guard !files.isEmpty else { return }
        isPreparing = true
        preparedCount = 0
        exportError = nil
        let batchID = UUID()
        transferQueue.track(batchID: batchID)

        do {
            for file in files {
                let didAccess = file.url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { file.url.stopAccessingSecurityScopedResource() }
                }
                _ = try await transferQueue.enqueueFile(
                    at: file.url,
                    filename: file.name,
                    destinationID: destination.id,
                    batchID: batchID
                )
                preparedCount += 1
            }
            files = []
            isPreparing = false
            await transferQueue.startUserInitiatedTransfer()
        } catch {
            isPreparing = false
            exportError = error.localizedDescription
            await transferQueue.startUserInitiatedTransfer()
        }
    }
}

private struct SelectedFile: Identifiable {
    let url: URL

    var id: URL { url.standardizedFileURL }

    var name: String { url.lastPathComponent }

    var detail: String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return url.pathExtension.uppercased()
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var symbolName: String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        return "doc"
    }
}
