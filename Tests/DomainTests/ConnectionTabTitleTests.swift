import XCTest
@testable import Domain

/// Contract tests for the pure console-tab-title rule (#99). They describe what
/// `ConnectionTabTitle` promises outward — a connection tab reads "Folder/connection" when the
/// folder-prefix preference is on and the connection is in a folder, and the bare name otherwise —
/// not how it works inside. Don't edit a contract test to make an implementation pass; if the
/// contract is wrong, flag it.
final class ConnectionTabTitleTests: XCTestCase {
    func testFolderIsPrefixedWhenEnabledAndPresent() {
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: "Work", showFolder: true),
            "Work/prod")
    }

    func testUngroupedConnectionShowsBareNameWhenEnabled() {
        // nil folder means the connection isn't in any folder — no prefix.
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: nil, showFolder: true),
            "prod")
    }

    func testDanglingFolderShowsBareName() {
        // An empty/whitespace folder name (e.g. a folderId that resolves to nothing) never prefixes.
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: "", showFolder: true),
            "prod")
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: "   \n\t", showFolder: true),
            "prod")
    }

    func testDisabledPrefShowsBareNameEvenInAFolder() {
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: "Work", showFolder: false),
            "prod")
    }

    func testFolderNameIsTrimmed() {
        XCTAssertEqual(
            ConnectionTabTitle.compose(connectionName: "prod", folderName: "  Work  ", showFolder: true),
            "Work/prod")
    }
}
