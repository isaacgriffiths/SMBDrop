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

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView {
                        Label("Choose Files", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Browse the Files app, select any documents, then send them to one of your SMB shares.")
                    } actions: {
                        Button("Browse Files") {
                            isShowingImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section("Selected") {
                            ForEach(files) { file in
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
                                }
                            }
                            .onDelete { offsets in
                                files.remove(atOffsets: offsets)
                            }

                            Button {
                                isShowingImporter = true
                            } label: {
                                Label("Add More Files", systemImage: "plus")
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
            .safeAreaInset(edge: .bottom) {
                if transferQueue.activeProgress != nil {
                    TransferActivityView(transferQueue: transferQueue)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Browse", systemImage: "folder")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send \(files.count)") {
                        if destinations.isEmpty {
                            selectedTab = .settings
                        } else {
                            isChoosingDestination = true
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(files.isEmpty || isPreparing)
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
        }
    }

    private func appendFiles(_ urls: [URL]) {
        let existing = Set(files.map { $0.url.standardizedFileURL })
        files.append(contentsOf: urls.compactMap { url in
            guard !existing.contains(url.standardizedFileURL) else { return nil }
            return SelectedFile(url: url)
        })
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
            await transferQueue.resume()
        } catch {
            isPreparing = false
            exportError = error.localizedDescription
            await transferQueue.resume()
        }
    }
}

private struct SelectedFile: Identifiable {
    let id = UUID()
    let url: URL

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
