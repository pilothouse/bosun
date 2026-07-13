import Foundation

public enum ConnectionTabTitle {
    /// The label for a connection's console tab (#99). When `showFolder` is on and the connection
    /// sits in a folder, prefix the name with "Folder/"; otherwise just the connection name. An
    /// ungrouped connection or a dangling `folderId` (resolved `folderName` nil/empty) always yields
    /// the bare name. Pure — one rule shared by the tab strip and the window titlebar so they can't
    /// drift. Mirrors `TerminalTitlePolicy` / `WindowTitlePolicy`.
    public static func compose(connectionName: String, folderName: String?, showFolder: Bool) -> String {
        guard showFolder,
              let folder = folderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return connectionName }
        return "\(folder)/\(connectionName)"
    }
}
