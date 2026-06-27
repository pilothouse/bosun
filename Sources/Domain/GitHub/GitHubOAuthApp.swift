import Foundation

/// The OAuth App the user signed in with. Pure rules about it live here so the App layer can build
/// (and tests can assert) the right GitHub links without touching AppKit or the network.
public enum GitHubOAuthApp {
    /// The GitHub page where the user grants or revokes this OAuth App's access to their account and
    /// organizations — `github.com/settings/connections/applications/<client_id>`. Opening it lets
    /// the user change per-org authorization; the app then re-syncs the visible org set.
    public static func connectionsURL(clientID: String) -> URL {
        let id = clientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clientID
        return URL(string: "https://github.com/settings/connections/applications/\(id)")
            ?? URL(string: "https://github.com/settings/applications")!
    }
}
