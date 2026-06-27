import XCTest
@testable import Domain

/// Contract test for the connections-on-disk migration: a `connections.json` written before the
/// folders feature has no `folderId` key, and it must still decode — every connection ungrouped.
/// Synthesized `Codable` gives this for free (an absent optional decodes to `nil`); the test pins
/// it so a future hand-written initializer can't silently break the migration.
final class ConnectionCodableTests: XCTestCase {

    func testLegacyConnectionWithoutFolderIdDecodesAsUngrouped() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "db-primary",
          "kind": { "ssh": { "host": "db.example.com", "port": 22, "user": "ops" } },
          "isFavorite": false
        }
        """.data(using: .utf8)!

        let connection = try JSONDecoder().decode(Connection.self, from: legacy)

        XCTAssertEqual(connection.name, "db-primary")
        XCTAssertNil(connection.folderId, "a missing folderId decodes to nil — ungrouped")
    }

    func testFolderIdRoundTrips() throws {
        let folder = UUID()
        let original = Connection(id: UUID(), name: "web", kind: .localFolder(path: "/srv/web"),
                                  folderId: folder)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(decoded.folderId, folder)
    }
}
