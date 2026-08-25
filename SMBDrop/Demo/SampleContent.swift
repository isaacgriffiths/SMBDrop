import UIKit

/// Stand-in content shown instead of the user's real photos, files, shares,
/// and transfer history, so App Store screenshots can be taken without
/// exposing anything personal. Toggled from Settings; every data source
/// checks the flag at load time.
enum SampleContent {
    static let defaultsKey = "sampleContentEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    // MARK: Shares

    static let photosShareID = UUID(uuidString: "6E1A2F55-0000-4000-8000-000000000001")!
    static let mediaShareID = UUID(uuidString: "6E1A2F55-0000-4000-8000-000000000002")!

    static var destinations: [DestinationSummary] {
        guard let photos = try? Destination(
            host: "homenas.local",
            share: "Photos",
            subfolder: "iPhone",
            username: "family"
        ), let media = try? Destination(
            host: "homenas.local",
            share: "Media",
            subfolder: "",
            username: "family"
        ) else {
            return []
        }
        return [
            DestinationSummary(id: photosShareID, destination: photos),
            DestinationSummary(id: mediaShareID, destination: media),
        ]
    }

    static var destinationNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0.displayName) })
    }

    // MARK: Photos

    struct Photo: Identifiable, Hashable {
        let seed: Int
        let isVideo: Bool
        let durationSeconds: Int

        var id: String { "sample-photo-\(seed)" }
    }

    static let photos: [Photo] = (0..<48).map { seed in
        Photo(
            seed: seed,
            isVideo: seed % 9 == 4,
            durationSeconds: 12 + (seed * 37) % 170
        )
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    /// Deterministic little landscape so the grid reads as a photo library
    /// while obviously being sample imagery.
    static func image(for photo: Photo, size: CGSize) -> UIImage {
        let renderSize = CGSize(
            width: max(64, min(600, size.width)),
            height: max(64, min(600, size.height))
        )
        let key = "\(photo.seed)-\(Int(renderSize.width))x\(Int(renderSize.height))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }

        let palettes: [(sky: UIColor, horizon: UIColor, land: UIColor)] = [
            (UIColor(red: 0.36, green: 0.58, blue: 0.89, alpha: 1), UIColor(red: 0.95, green: 0.80, blue: 0.62, alpha: 1), UIColor(red: 0.18, green: 0.32, blue: 0.36, alpha: 1)),
            (UIColor(red: 0.94, green: 0.55, blue: 0.42, alpha: 1), UIColor(red: 0.97, green: 0.83, blue: 0.55, alpha: 1), UIColor(red: 0.33, green: 0.21, blue: 0.34, alpha: 1)),
            (UIColor(red: 0.24, green: 0.28, blue: 0.48, alpha: 1), UIColor(red: 0.60, green: 0.48, blue: 0.72, alpha: 1), UIColor(red: 0.12, green: 0.14, blue: 0.24, alpha: 1)),
            (UIColor(red: 0.44, green: 0.72, blue: 0.66, alpha: 1), UIColor(red: 0.88, green: 0.93, blue: 0.79, alpha: 1), UIColor(red: 0.20, green: 0.40, blue: 0.33, alpha: 1)),
            (UIColor(red: 0.83, green: 0.44, blue: 0.47, alpha: 1), UIColor(red: 0.96, green: 0.72, blue: 0.62, alpha: 1), UIColor(red: 0.28, green: 0.16, blue: 0.24, alpha: 1)),
            (UIColor(red: 0.51, green: 0.66, blue: 0.85, alpha: 1), UIColor(red: 0.87, green: 0.90, blue: 0.95, alpha: 1), UIColor(red: 0.26, green: 0.33, blue: 0.44, alpha: 1)),
        ]
        let palette = palettes[photo.seed % palettes.count]
        let variant = CGFloat((photo.seed * 53) % 100) / 100

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: renderSize)
            let colors = [palette.sky.cgColor, palette.horizon.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: renderSize.height),
                    options: []
                )
            }

            // Sun
            let sunDiameter = renderSize.width * (0.16 + 0.10 * variant)
            let sunX = renderSize.width * (0.15 + 0.6 * variant)
            let sunY = renderSize.height * (0.18 + 0.25 * (1 - variant))
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.cgContext.fillEllipse(
                in: CGRect(x: sunX, y: sunY, width: sunDiameter, height: sunDiameter)
            )

            // Hills
            palette.land.setFill()
            let horizon = renderSize.height * (0.55 + 0.18 * variant)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: renderSize.height))
            path.addLine(to: CGPoint(x: 0, y: horizon))
            path.addCurve(
                to: CGPoint(x: renderSize.width, y: horizon + renderSize.height * 0.08),
                controlPoint1: CGPoint(x: renderSize.width * 0.35, y: horizon - renderSize.height * (0.10 + 0.12 * variant)),
                controlPoint2: CGPoint(x: renderSize.width * 0.7, y: horizon + renderSize.height * 0.12)
            )
            path.addLine(to: CGPoint(x: renderSize.width, y: renderSize.height))
            path.close()
            path.fill()
        }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Browsable share contents

    static func remoteItems(at relativePath: String) -> [SMBRemoteItem] {
        func file(_ name: String, _ bytes: Int64, daysAgo: Double) -> SMBRemoteItem {
            SMBRemoteItem(
                name: name,
                relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                isDirectory: false,
                byteCount: bytes,
                modificationDate: Date().addingTimeInterval(-86_400 * daysAgo)
            )
        }
        func folder(_ name: String) -> SMBRemoteItem {
            SMBRemoteItem(
                name: name,
                relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                isDirectory: true,
                byteCount: nil,
                modificationDate: nil
            )
        }

        if relativePath.isEmpty {
            return [
                folder("2025"),
                folder("2026"),
                folder("Scans"),
                file("Family_BBQ.MOV", 154_000_000, daysAgo: 3),
                file("IMG_5210.HEIC", 2_800_000, daysAgo: 2),
                file("IMG_5211.HEIC", 3_100_000, daysAgo: 2),
                file("Renovation_quotes.pdf", 240_000, daysAgo: 9),
            ]
        }
        return [
            folder("Birthday"),
            file("IMG_4874.HEIC", 2_400_000, daysAgo: 40),
            file("IMG_4880.HEIC", 3_400_000, daysAgo: 39),
            file("Garden_timelapse.MOV", 214_000_000, daysAgo: 35),
        ]
    }

    // MARK: Transfer history

    static var transfers: [Transfer] {
        func completed(_ name: String, _ bytes: Int64, minutesAgo: Double) -> Transfer {
            let stamp = Date().addingTimeInterval(-60 * minutesAgo)
            return Transfer(
                id: UUID(),
                filename: name,
                byteCount: bytes,
                createdAt: stamp.addingTimeInterval(-90),
                sourceCreationDate: nil,
                sourceModificationDate: nil,
                destinationID: photosShareID,
                batchID: nil,
                updatedAt: stamp,
                status: .completed,
                bytesTransferred: bytes,
                attemptCount: 1,
                remoteFilename: name,
                errorMessage: nil
            )
        }
        return [
            completed("IMG_5203.HEIC", 3_200_000, minutesAgo: 96),
            completed("IMG_5204.HEIC", 2_900_000, minutesAgo: 95),
            completed("IMG_5205.HEIC", 3_500_000, minutesAgo: 94),
            completed("Garden_timelapse.MOV", 214_000_000, minutesAgo: 88),
        ]
    }

    // MARK: Imported files on this iPhone

    /// A catalog of generated sample files, created on demand in Caches so
    /// they never appear in the user's real Files provider.
    static func importsCatalog() throws -> ImportedFileCatalog {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SampleImports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try ensureSampleFiles(in: directory)
        return ImportedFileCatalog(directoryURL: directory)
    }

    private static func ensureSampleFiles(in directory: URL) throws {
        let fileManager = FileManager.default

        for (index, name) in ["IMG_4874.HEIC.jpg", "IMG_4880.HEIC.jpg", "Sunset_pier.jpg"].enumerated() {
            let url = directory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            let photo = Photo(seed: 7 + index * 11, isVideo: false, durationSeconds: 0)
            let data = image(for: photo, size: CGSize(width: 600, height: 450))
                .jpegData(compressionQuality: 0.85)
            try data?.write(to: url)
            stampDate(url, daysAgo: Double(index + 1))
        }

        let pdfURL = directory.appendingPathComponent("Renovation_quotes.pdf")
        if !fileManager.fileExists(atPath: pdfURL.path) {
            let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
            let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
                context.beginPage()
                "Renovation quotes".draw(
                    at: CGPoint(x: 56, y: 64),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)]
                )
                "Sample document imported from //homenas.local/Photos.".draw(
                    at: CGPoint(x: 56, y: 108),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13)]
                )
            }
            try data.write(to: pdfURL)
            stampDate(pdfURL, daysAgo: 5)
        }

        let notesURL = directory.appendingPathComponent("Server notes.txt")
        if !fileManager.fileExists(atPath: notesURL.path) {
            try Data("Sample file imported with SMBDrop.\n".utf8).write(to: notesURL)
            stampDate(notesURL, daysAgo: 8)
        }
    }

    private static func stampDate(_ url: URL, daysAgo: Double) {
        let date = Date().addingTimeInterval(-86_400 * daysAgo)
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}

/// Serves the sample share tree and simulates imports while Sample Content
/// is on, so the Import tab is fully usable without any network.
struct SampleImportService: SMBImportServing {
    func contents(
        of destinationID: UUID,
        at relativePath: String
    ) async throws -> [SMBRemoteItem] {
        try? await Task.sleep(nanoseconds: 250_000_000)
        return SampleContent.remoteItems(at: relativePath)
    }

    func importItems(
        _ items: [SMBRemoteItem],
        from destinationID: UUID,
        progress: @escaping @Sendable (SMBImportProgress) -> Void
    ) async throws -> [URL] {
        let catalog = try SampleContent.importsCatalog()
        var imported: [URL] = []
        for (index, item) in items.enumerated() {
            let total = item.byteCount ?? 1_000_000
            progress(
                SMBImportProgress(
                    filename: item.name,
                    completedItemCount: index,
                    totalItemCount: items.count,
                    bytesTransferred: total / 2,
                    totalBytes: total
                )
            )
            try? await Task.sleep(nanoseconds: 350_000_000)
            let url = catalog.directoryURL.appendingPathComponent(item.name + ".jpg")
            if !FileManager.default.fileExists(atPath: url.path) {
                let photo = SampleContent.Photo(
                    seed: 20 + index * 13,
                    isVideo: false,
                    durationSeconds: 0
                )
                let data = SampleContent.image(for: photo, size: CGSize(width: 600, height: 450))
                    .jpegData(compressionQuality: 0.85)
                try data?.write(to: url)
            }
            imported.append(url)
        }
        return imported
    }
}
