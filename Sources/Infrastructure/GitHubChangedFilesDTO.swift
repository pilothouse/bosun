import Domain
import Foundation

/// The GraphQL DTO for a PR's changed-file list (`PullRequest.files`). Split out of
/// `GitHubAPIClient` to keep that file under the line-length cap; `ItemNode` references it through
/// the module. `internal`, not `private`, so the cross-file reference resolves.
struct FilesConnection: Decodable {
    let nodes: [FileNode]

    struct FileNode: Decodable {
        let path: String
        let additions: Int
        let deletions: Int
        let changeType: String

        func toDomain() -> GitHubFile {
            GitHubFile(path: path, additions: additions, deletions: deletions,
                       change: Self.change(fromGraphQL: changeType))
        }

        /// GraphQL `PatchStatus` is UPPER_SNAKE; map onto the REST-canonical domain vocabulary
        /// (`DELETED → .removed`). Anything unrecognized degrades to `.changed` rather than throw.
        private static func change(fromGraphQL changeType: String) -> GitHubFileChange {
            changeType == "DELETED"
                ? .removed
                : GitHubFileChange(rawValue: changeType.lowercased()) ?? .changed
        }
    }
}
