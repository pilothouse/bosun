import Foundation

/// Unvalidated folder input from the rail's create/rename affordance. `id == nil` means a brand-new
/// folder; a non-nil `id` renames the existing one (the App layer preserves it on save). Mirrors
/// `ConnectionDraft`.
public struct FolderDraft: Sendable, Equatable {
    public let id: UUID?
    public var name: String

    public init(id: UUID?, name: String) {
        self.id = id
        self.name = name
    }
}

/// What can be wrong with a folder draft. A folder has one field, so one case.
public enum FolderValidationError: Sendable, Equatable {
    case emptyName
}

/// The rule: is this draft a saveable folder? Pure — one unit test, callable from the rail, a CLI
/// importer, or a migration alike. Lives in Domain because it has an `if`. Mirrors `ConnectionPolicy`.
public enum FolderPolicy {
    public static func validate(name: String) -> [FolderValidationError] {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.emptyName] : []
    }
}
