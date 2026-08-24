import Foundation

struct LoadedShareItem {
    let temporaryURL: URL
    let filename: String
}

enum ShareItemFileStager {
    static func stage(
        sourceURL: URL,
        suggestedName: String?,
        typeIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> LoadedShareItem {
        let filename = try ShareItemFilename.resolve(
            suggestedName: suggestedName,
            sourceURL: sourceURL,
            typeIdentifier: typeIdentifier
        )
        let sourceDates = try sourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        guard sourceDates.contentModificationDate != nil else {
            throw ShareItemFileStagingError.sourceTimestampUnavailable
        }
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        let temporaryURL = temporaryDirectory.appendingPathComponent(
            filename,
            isDirectory: false
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            var attributes: [FileAttributeKey: Any] = [:]
            if let creationDate = sourceDates.creationDate {
                attributes[.creationDate] = creationDate
            }
            if let modificationDate = sourceDates.contentModificationDate {
                attributes[.modificationDate] = modificationDate
            }
            if !attributes.isEmpty {
                try fileManager.setAttributes(attributes, ofItemAtPath: temporaryURL.path)
            }
            return LoadedShareItem(temporaryURL: temporaryURL, filename: filename)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }
}

enum ShareItemFileStagingError: LocalizedError {
    case sourceTimestampUnavailable

    var errorDescription: String? {
        "Photos did not provide the original file timestamp, so SMBDrop did not replace it with the upload time."
    }
}
