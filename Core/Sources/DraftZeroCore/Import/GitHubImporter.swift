import Foundation
import PDFKit

/// GitHub 导入（R-002）：公开仓库/单文件，保存来源路径与所读版本标识（tree SHA）。
/// 依据 SPEC §7：目录/树接口存在数量与大小限制，截断必须标明"列表不完整"。
public enum GitHubLinkParser {

    public enum Kind: Sendable, Equatable {
        case repo
        case file
    }

    public struct Ref: Sendable, Equatable {
        public let kind: Kind
        public let owner: String
        public let repo: String
        /// 分支/标签/SHA；nil 表示用默认分支。
        public let ref: String?
        /// 文件路径（file 类）；仓库子目录前缀（tree 类，可空）。
        public let path: String?

        public init(kind: Kind, owner: String, repo: String, ref: String? = nil, path: String? = nil) {
            self.kind = kind
            self.owner = owner
            self.repo = repo
            self.ref = ref
            self.path = path
        }
    }

    /// 解析 github.com 链接：仓库、tree（含子目录）、blob 单文件。
    public static func parse(_ raw: String) -> Ref? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host, host == "github.com" else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if parts.count == 2 && repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        guard parts.count == 2 else {
            guard parts.count >= 3 else { return nil }
            switch parts[2] {
            case "blob":
                guard parts.count >= 5 else { return nil }
                let branch = parts[3]
                let path = parts[4...].joined(separator: "/")
                return Ref(kind: .file, owner: owner, repo: repo, ref: branch, path: path)
            case "tree":
                guard parts.count >= 4 else { return nil }
                let branch = parts[3]
                let subpath = parts.count > 4 ? parts[4...].joined(separator: "/") : nil
                return Ref(kind: .repo, owner: owner, repo: repo, ref: branch, path: subpath)
            default:
                return nil
            }
        }
        return Ref(kind: .repo, owner: owner, repo: repo)
    }
}

/// GitHub REST/raw 客户端。网络层可注入以便离线测试。
public struct GitHubClient: Sendable {

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public enum GitHubError: LocalizedError, Equatable {
        case notFoundOrPrivate
        case rateLimited
        case unavailable(code: Int)
        case badPayload

        public var errorDescription: String? {
            switch self {
            case .notFoundOrPrivate: "仓库或文件不存在、已失效，或为私有内容"
            case .rateLimited: "GitHub 服务限制（未认证请求每小时 60 次），请稍后重试"
            case .unavailable(let code): "GitHub 返回错误（HTTP \(code)）"
            case .badPayload: "GitHub 返回了无法解析的数据"
            }
        }
    }

    public struct RepoInfo: Decodable, Sendable {
        public let default_branch: String
    }

    public struct TreeEntry: Decodable, Sendable, Equatable {
        public let path: String
        public let type: String
        public let sha: String
        public let size: Int?
    }

    struct TreeResponse: Decodable {
        let sha: String
        let truncated: Bool?
        let tree: [TreeEntry]
    }

    struct CommitList: Decodable {
        let sha: String
    }

    public let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.defaultFetch
    }

    public static let defaultFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: HTTPUserAgent.stamped(request))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("DraftZero/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 403, 429:
            if (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "1") == "0" {
                throw GitHubError.rateLimited
            }
            throw GitHubError.rateLimited
        case 404, 301:
            throw GitHubError.notFoundOrPrivate
        case 451:
            throw GitHubError.unavailable(code: 451)
        default:
            throw GitHubError.unavailable(code: response.statusCode)
        }
    }

    /// 默认分支。ref 已知时跳过。
    public func defaultBranch(owner: String, repo: String) async throws -> String {
        let info = try await get(URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!)
        guard let decoded = try? JSONDecoder().decode(RepoInfo.self, from: info) else {
            throw GitHubError.badPayload
        }
        return decoded.default_branch
    }

    /// 仓库文件树（含截断标记，R-002"列表不完整"）。
    public func listTree(owner: String, repo: String, ref: String) async throws
        -> (treeSha: String, entries: [TreeEntry], truncated: Bool) {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(ref)?recursive=1")!
        let data = try await get(url)
        guard let decoded = try? JSONDecoder().decode(TreeResponse.self, from: data) else {
            throw GitHubError.badPayload
        }
        return (decoded.sha, decoded.tree, decoded.truncated ?? false)
    }

    /// 单文件所读版本的标识：该路径最近一次提交的 SHA。
    public func latestCommitSha(owner: String, repo: String, ref: String, path: String) async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits?path=\(encoded)&sha=\(ref)&per_page=1")!
        let data = try await get(url)
        guard let list = try? JSONDecoder().decode([CommitList].self, from: data), let sha = list.first?.sha else {
            throw GitHubError.badPayload
        }
        return sha
    }

    /// 下载文件原始内容（raw 域名，不受 API 限额约束）。
    public func downloadRaw(owner: String, repo: String, ref: String, path: String) async throws -> Data {
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { throw GitHubError.notFoundOrPrivate }
            throw GitHubError.unavailable(code: response.statusCode)
        }
        return data
    }
}

/// GitHub 文件导入器：文本入库存为只读快照，PDF 落盘快照。
/// 来源路径为 blob URL，版本标识为 tree SHA（批量）或 commit SHA（单文件）。
public struct GitHubImporter: Sendable {

    public static let maxTextFileSize = 2_000_000

    public let database: AppDatabase
    public let snapshotsDirectory: URL
    public let client: GitHubClient

    public init(database: AppDatabase, snapshotsDirectory: URL, client: GitHubClient = GitHubClient()) {
        self.database = database
        self.snapshotsDirectory = snapshotsDirectory
        self.client = client
    }

    // MARK: - 仓库批量（从勾选列表进入，树 SHA 已知）

    public func importFile(request: GitHubImportRequest, allowDuplicate: Bool = false) async -> ImportOutcome {
        guard LocalFileImporter.supportedExtensions.contains(request.fileExtension) else {
            return .failure(reason: "不支持的文件类型：\(request.path)")
        }
        let data: Data
        do {
            data = try await client.downloadRaw(
                owner: request.owner, repo: request.repo,
                ref: request.branch, path: request.path)
        } catch {
            return .failure(reason: error.localizedDescription)
        }
        return await store(data: data, request: request, versionSha: request.treeSha, allowDuplicate: allowDuplicate)
    }

    // MARK: - 单文件链接（版本标识取最近提交 SHA）

    public func importSingleFile(ref: GitHubLinkParser.Ref, allowDuplicate: Bool = false) async -> ImportOutcome {
        guard ref.kind == .file, let path = ref.path else {
            return .failure(reason: "不是 GitHub 单文件链接")
        }
        do {
            let branch: String
            if let known = ref.ref {
                branch = known
            } else {
                branch = try await client.defaultBranch(owner: ref.owner, repo: ref.repo)
            }
            let commitSha = try await client.latestCommitSha(
                owner: ref.owner, repo: ref.repo, ref: branch, path: path)
            let data = try await client.downloadRaw(
                owner: ref.owner, repo: ref.repo, ref: branch, path: path)
            let request = GitHubImportRequest(
                owner: ref.owner, repo: ref.repo, branch: branch,
                treeSha: commitSha, path: path, blobSha: commitSha)
            return await store(data: data, request: request, versionSha: commitSha, allowDuplicate: allowDuplicate)
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // MARK: - 内容落库（本地导入共用逻辑）

    func store(data: Data, request: GitHubImportRequest, versionSha: String, allowDuplicate: Bool) async -> ImportOutcome {
        let sourceLocation = request.blobURL.absoluteString
        if request.fileExtension == "pdf" {
            guard let document = PDFDocument(data: data) else {
                return .failure(reason: "不是可读取的 PDF：\(request.path)")
            }
            var pieces: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let text = page.string {
                    pieces.append(text)
                }
            }
            let text = pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = text.count >= PDFTextExtractor.minimumExtractableCharacters

            let destination = snapshotsDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
            do {
                try data.write(to: destination)
            } catch {
                return .failure(reason: "无法保存 PDF 快照：\(error.localizedDescription)")
            }
            let fingerprint = hasText ? TextReading.fingerprint(of: text) : nil
            if !allowDuplicate,
               let existing = try? await database.findExistingDraft(
                   sourceLocation: sourceLocation, fingerprint: fingerprint) {
                try? FileManager.default.removeItem(at: destination)
                return .duplicate(existing: existing)
            }
            let draft = Draft(
                title: (request.path as NSString).lastPathComponent,
                content: hasText ? text : nil,
                isEditable: false,
                hasExtractableText: hasText,
                sourceType: .githubFile,
                sourceLocation: sourceLocation,
                sourceLabel: "\(request.owner)/\(request.repo)：\(request.path)",
                snapshotFileURL: destination.path,
                fingerprint: fingerprint,
                sourceVersionSha: versionSha)
            do {
                return .success(try await database.insertDraft(draft, initialVersion: true))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return .failure(reason: "保存失败：\(error.localizedDescription)")
            }
        }

        // 文本文件：UTF-8 优先，GB18030 回退。
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let gb = WebPageExtractor.decode(data) {
            text = gb
        } else {
            return .failure(reason: "无法识别文件编码：\(request.path)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(reason: "文件没有可读取的正文：\(request.path)")
        }

        let fingerprint = TextReading.fingerprint(of: text)
        if !allowDuplicate,
           let existing = try? await database.findExistingDraft(
               sourceLocation: sourceLocation, fingerprint: fingerprint) {
            return .duplicate(existing: existing)
        }

        let title = TextReading.extractTitle(
            from: text, fallback: (request.path as NSString).lastPathComponent)
        let draft = Draft(
            title: title,
            content: text,
            isEditable: false,
            sourceType: .githubFile,
            sourceLocation: sourceLocation,
            sourceLabel: "\(request.owner)/\(request.repo)：\(request.path)",
            fingerprint: fingerprint,
            sourceVersionSha: versionSha)
        do {
            return .success(try await database.insertDraft(draft, initialVersion: true))
        } catch {
            return .failure(reason: "保存失败：\(error.localizedDescription)")
        }
    }
}
