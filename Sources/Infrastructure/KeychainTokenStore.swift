import Application
import Foundation
import Security

/// Keychain adapter for the `GitHubTokenStore` port: the OAuth token stored as a generic-
/// password item keyed by (service, account). `import Security` is allowed here — this is the
/// only place that touches the Keychain. An actor serializes access and gives us free
/// `Sendable` correctness, mirroring the other stores. The token is never logged; errors carry
/// only the OSStatus.
public actor KeychainTokenStore: GitHubTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "com.bosun.workbench.github",
                account: String = "oauth-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AuthError.transport("keychain read failed: \(status)")
        }
        return token
    }

    public func save(_ token: String) throws {
        try delete()   // upsert: clear any existing item first so a re-login overwrites cleanly
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        // Readable without a prompt while the device is unlocked; survives relaunch.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.transport("keychain write failed: \(status)")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.transport("keychain delete failed: \(status)")
        }
    }
}
