import Foundation

public struct AgentRun: Sendable, Identifiable {
    public let id: UUID
    public let repo: RepoRef
    public let prompt: String
    public private(set) var status: RunStatus

    public init(id: UUID, repo: RepoRef, prompt: String, status: RunStatus = .queued) {
        self.id = id
        self.repo = repo
        self.prompt = prompt
        self.status = status
    }
}

public enum RunStatus: Sendable, Equatable {
    case queued, running, succeeded, failed(reason: String)
}

public struct RepoRef: Sendable, Equatable {
    public let forge: Forge
    public let owner: String
    public let name: String

    public init(forge: Forge, owner: String, name: String) {
        self.forge = forge
        self.owner = owner
        self.name = name
    }
}

public enum Forge: Sendable, Equatable {
    case github
    case gitea(host: String)
    case forgejo(host: String)
}
