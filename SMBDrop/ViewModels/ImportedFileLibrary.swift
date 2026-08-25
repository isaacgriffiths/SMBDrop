import Combine
import Foundation
import Photos
import UniformTypeIdentifiers

struct ImportedFile: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case image
        case video
        case document
    }

    let url: URL
    let byteCount: Int64
    let modificationDate: Date?
    let kind: Kind

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var canSaveToPhotos: Bool { kind == .image || kind == .video }

    var detail: String {
        var values = [ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)]
        if let modificationDate {
            values.append(modificationDate.formatted(date: .abbreviated, time: .shortened))
        }
        return values.joined(separator: " · ")
    }

    static func kind(for url: URL) -> Kind {
        guard let contentType = UTType(filenameExtension: url.pathExtension) else {
            return .document
        }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .movie) { return .video }
        return .document
    }
}

struct ImportedFileCatalog {
    let directoryURL: URL

    static func appCatalog(fileManager: FileManager = .default) throws -> Self {
        Self(directoryURL: try SMBImportService.defaultImportDirectory(fileManager: fileManager))
    }

    func items(fileManager: FileManager = .default) throws -> [ImportedFile] {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )
        return try urls.compactMap { url -> ImportedFile? in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isHidden != true,
                  url.pathExtension.caseInsensitiveCompare("partial") != .orderedSame else {
                return nil
            }
            return ImportedFile(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate,
                kind: ImportedFile.kind(for: url)
            )
        }
        .sorted { lhs, rhs in
            let leftDate = lhs.modificationDate ?? .distantPast
            let rightDate = rhs.modificationDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

@MainActor
final class ImportedFileLibrary: ObservableObject {
    @Published private(set) var items: [ImportedFile] = []
    @Published private(set) var confirmationMessage: String?
    @Published var errorMessage: String?

    private let catalog: ImportedFileCatalog?

    init(catalog: ImportedFileCatalog? = try? ImportedFileCatalog.appCatalog()) {
        self.catalog = catalog
        reload()
    }

    var mediaItems: [ImportedFile] {
        items.filter { $0.kind == .image || $0.kind == .video }
    }

    var documentItems: [ImportedFile] {
        items.filter { $0.kind == .document }
    }

    func reload() {
        guard let catalog else {
            items = []
            errorMessage = SMBImportError.importDirectoryUnavailable.localizedDescription
            return
        }
        do {
            items = try catalog.items()
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    func saveToPhotos(_ item: ImportedFile) async {
        guard item.canSaveToPhotos else { return }
        errorMessage = nil
        confirmationMessage = nil

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "Allow SMBDrop to add photos in Settings, then try again."
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                switch item.kind {
                case .image:
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.url)
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                case .document:
                    break
                }
            }
            confirmationMessage = "Saved \(item.name) to Photos."
        } catch {
            errorMessage = "Couldn’t save \(item.name) to Photos. \(error.localizedDescription)"
        }
    }

    func clearConfirmation() {
        confirmationMessage = nil
    }
}
