import XCTest
@testable import SMBDrop

final class SMBConnectionTesterTests: XCTestCase {
    func testConnectionRejectsAFileAsTheConfiguredSubfolder() {
        XCTAssertThrowsError(
            try SMBConnectionTester.validateSubfolderAttributes([
                .isDirectoryKey: false
            ])
        ) { error in
            XCTAssertEqual(error as? SMBConnectionError, .shareOrFolderMissing)
        }
    }
}
