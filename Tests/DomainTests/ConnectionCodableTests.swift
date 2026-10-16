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

    func testLegacyConnectionWithoutUpdatedAtDecodesAsNil() throws {
        // The same pre-sync payload above carries no `updatedAt`; the merge reads `nil` as "oldest".
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "db-primary",
          "kind": { "ssh": { "host": "db.example.com", "port": 22, "user": "ops" } },
          "isFavorite": false
        }
        """.data(using: .utf8)!

        let connection = try JSONDecoder().decode(Connection.self, from: legacy)

        XCTAssertNil(connection.updatedAt, "a missing updatedAt decodes to nil — a never-synced record")
    }

    func testUpdatedAtRoundTrips() throws {
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Connection(id: UUID(), name: "web", kind: .localFolder(path: "/srv/web"),
                                  updatedAt: stamped)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(decoded.updatedAt, stamped)
    }

    // MARK: - Color (#102)

    /// The pre-color payload: no `color` key at all.
    private let legacyJSON = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name": "db-primary",
      "kind": { "ssh": { "host": "db.example.com", "port": 22, "user": "ops" } },
      "isFavorite": false
    }
    """

    func testLegacyConnectionWithoutColorDecodesAsNoColor() throws {
        let connection = try JSONDecoder().decode(Connection.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(connection.color, "a missing color decodes to nil — the connection looks as it did")
    }

    func testUnknownColorDecodesAsNoColorAndKeepsTheRecord() throws {
        // A store written by a newer build may carry a color this build doesn't know.
        let newer = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "db-primary",
          "kind": { "ssh": { "host": "db.example.com", "port": 22, "user": "ops" } },
          "isFavorite": true,
          "folderId": "00000000-0000-0000-0000-0000000000F1",
          "color": "magenta"
        }
        """

        let connection = try JSONDecoder().decode(Connection.self, from: Data(newer.utf8))

        XCTAssertNil(connection.color, "an unknown color decodes to nil instead of throwing")
        XCTAssertEqual(connection.name, "db-primary")
        XCTAssertTrue(connection.isFavorite)
        XCTAssertEqual(connection.folderId, UUID(uuidString: "00000000-0000-0000-0000-0000000000F1"))
    }

    func testWrongTypedColorDecodesAsNoColor() throws {
        let odd = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "db-primary",
          "kind": { "localFolder": { "path": "/srv" } },
          "isFavorite": false,
          "color": 7
        }
        """

        let connection = try JSONDecoder().decode(Connection.self, from: Data(odd.utf8))

        XCTAssertNil(connection.color)
        XCTAssertEqual(connection.kind, .localFolder(path: "/srv"))
    }

    func testColorRoundTripsUnderItsStorageKey() throws {
        let original = Connection(id: UUID(), name: "prod", kind: .ssh(host: "p", port: 22, user: nil),
                                  color: .red)
        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(Connection.self, from: data), original)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["color"] as? String, "red", "stored under the stable raw value")
    }
}
