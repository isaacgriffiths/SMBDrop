import QuickLookThumbnailing
import SwiftUI
import UIKit

struct ImportedFileThumbnail: View {
    let item: ImportedFile
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: item.id) {
            image = await thumbnail()
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .image: "photo"
        case .video: "video"
        case .document: "doc"
        }
    }

    private func thumbnail() async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                representation,
                _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }
}
