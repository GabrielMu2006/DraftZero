import Foundation

/// 单次导入结果（本地文件/网页/GitHub 通用）。
public enum ImportOutcome: Sendable, Equatable {
    case success(Draft)
    /// 已有相同来源或相同内容的快照（SPEC §6：先提示，允许取消或另存新快照）。
    case duplicate(existing: Draft)
    case failure(reason: String)

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// 批量导入中的一项：displayName 供结果面板展示，source 供"另存新快照"重试。
public struct ImportedItem: Sendable {
    public enum Source: Sendable, Equatable {
        case localFile(URL)
        case webPage(URL)
        case githubFile(GitHubImportRequest)
    }

    public let displayName: String
    public let source: Source?
    public let outcome: ImportOutcome

    public init(displayName: String, source: Source?, outcome: ImportOutcome) {
        self.displayName = displayName
        self.source = source
        self.outcome = outcome
    }
}

/// 仓库中待导入文件所需的全部信息（树接口已给出 SHA，导入时只需下载 raw 内容）。
public struct GitHubImportRequest: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let branch: String
    public let treeSha: String
    public let path: String
    public let blobSha: String

    public init(owner: String, repo: String, branch: String, treeSha: String, path: String, blobSha: String) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.treeSha = treeSha
        self.path = path
        self.blobSha = blobSha
    }

    public var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    public var blobURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/blob/\(branch)/\(path)")!
    }
}
