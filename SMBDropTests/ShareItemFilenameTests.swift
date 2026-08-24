import UniformTypeIdentifiers
import XCTest
@testable import SMBDrop

final class ShareItemFilenameTests: XCTestCase {
    func testKeepsOriginalPhotosFilenameAndAddsItsMissingExtension() throws {
        let filename = try ShareItemFilename.resolve(
            suggestedName: "IMG_4522",
            sourceURL: URL(fileURLWithPath: "/tmp/copy_01234567-89AB-CDEF-0123-456789ABCDEF.PNG"),
            typeIdentifier: UTType.png.identifier
        )

        XCTAssertEqual(filename, "IMG_4522.PNG")
    }

    func testRejectsPhotosTemporaryCopyNameInsteadOfRenamingTheOriginal() {
        XCTAssertThrowsError(
            try ShareItemFilename.resolve(
                suggestedName: nil,
                sourceURL: URL(
                    fileURLWithPath: "/tmp/copy_A72AC284-601D-4FE6-9DB8-2C2792BFFEBC.MOV"
                ),
                typeIdentifier: UTType.quickTimeMovie.identifier
            )
        ) { error in
            XCTAssertEqual(error as? ShareItemFilenameError, .originalFilenameUnavailable)
        }
    }

    func testUsesOriginalInPlaceFilenameWhenPhotosProvidesIt() throws {
        let filename = try ShareItemFilename.resolve(
            suggestedName: nil,
            sourceURL: URL(fileURLWithPath: "/Photos/IMG_4523.MOV"),
            typeIdentifier: UTType.quickTimeMovie.identifier
        )

        XCTAssertEqual(filename, "IMG_4523.MOV")
    }
}
