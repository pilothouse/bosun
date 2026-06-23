import Foundation

/// Unvalidated connection input from the "New connection" form. `id == nil` means a brand-new
/// connection; a non-nil `id` edits the existing one (the App layer preserves it on save).
public struct ConnectionDraft: Sendable, Equatable {
    public let id: UUID?
    public var name: String
    public var kind: ConnectionKind
    public var isFavorite: Bool
    /// Optional post-connect command (SSH only); blank input is normalized to `nil` on save.
    public var customCommand: String?

    public init(id: UUID?, name: String, kind: ConnectionKind, isFavorite: Bool = false,
                customCommand: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isFavorite = isFavorite
        self.customCommand = customCommand
    }
}

/// What can be wrong with a draft. One case per field so the UI can point at the right input.
public enum ConnectionValidationError: Sendable, Equatable {
    case emptyName
    case emptyHost
    case invalidPort
    case emptyPath
}

/// The rule: is this draft a saveable connection? Pure — one unit test, callable from the
/// sheet, a CLI importer, or a migration alike. Lives in Domain because it has `if`s.
public enum ConnectionPolicy {
    public static func validate(_ draft: ConnectionDraft) -> [ConnectionValidationError] {
        var errors: [ConnectionValidationError] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyName)
        }
        switch draft.kind {
        case let .ssh(host, port, _):
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyHost)
            }
            if !(1...65_535).contains(port) {
                errors.append(.invalidPort)
            }
        case let .localFolder(path):
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyPath)
            }
        }
        return errors
    }
}
