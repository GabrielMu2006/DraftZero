import XCTest
import GRDB
@testable import DraftZeroCore

/// R-002 网页/GitHub 导入与 R-006 版本对比的数据层验收。
/// 网络层全部注入假 fetch，测试离线可跑。
final class WebGitHubDiffTests: XCTestCase {

    private var workspace: (root: URL, snapshots: URL)!

    override func setUpWithError() throws {
        workspace = try TestSupport.makeWorkspace()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
    }

    // MARK: - 假网络

    private func fakeFetch(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)
    ) -> GitHubClient.Fetch {
        { request in
            let (status, headers, body) = handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
    }

    // MARK: - 网页提取

    private static let fixtureHTML = """
    <html><head><title>评测周报 &amp; 摘要</title>
    <script>var junk = "SCRIPTJUNK";</script>
    <style>.x { color: red; }</style></head>
    <body><nav><ul><li>首页</li><li>登录</li></ul></nav>
    <article><p>这里是正文第一段，包含足够的文字用于提取测试，确保超过五十个字符的阈值线，中文场景下也应正常工作，补充一些字符凑足长度。</p>
    <p>第二段：更多内容，继续凑长度，让正文提取判定可以通过。</p></article>
    <footer>版权所有 FOOTERJUNK</footer></body></html>
    """

    func testWebPageExtractorStripsScriptNavFooterAndDecodesTitle() {
        let page = WebPageExtractor.extract(htmlData: Data(Self.fixtureHTML.utf8))
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.title, "评测周报 & 摘要")
        let text = page?.text ?? ""
        XCTAssertTrue(text.contains("正文第一段"))
        XCTAssertTrue(text.contains("第二段"))
        XCTAssertFalse(text.contains("SCRIPTJUNK"))
        XCTAssertFalse(text.contains("FOOTERJUNK"))
        XCTAssertFalse(text.contains("登录"))
    }

    func testWebPageExtractorRejectsShortBodies() {
        let page = WebPageExtractor.extract(htmlData: Data("<html><body><p>登录</p></body></html>".utf8))
        XCTAssertNil(page) // 登录墙/过短正文 → 失败而非空草稿
    }

    // MARK: - 网页导入

    func testWebImportStoresReadableSnapshot() async throws {
        let db = try TestSupport.makeDatabase()
        let web = WebImporter(database: db) { request in
            (Data(WebGitHubDiffTests.fixtureHTML.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
        }
        let url = URL(string: "https://example.com/weekly#section")!
        let outcome = await web.importWebPage(url: url)
        guard case .success(let draft) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertFalse(draft.isEditable) // 网页是只读快照（R-003）
        XCTAssertEqual(draft.title, "评测周报 & 摘要")
        XCTAssertTrue(draft.content?.contains("正文第一段") ?? false)
        // 锚点不进入来源标识
        XCTAssertEqual(draft.sourceLocation, "https://example.com/weekly")
        XCTAssertEqual(draft.sourceType, .web)
        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 1)

        // 同一页面重复添加 → 提示重复
        let second = await web.importWebPage(url: url)
        guard case .duplicate = second else { return XCTFail("expected duplicate, got \(second)") }
    }

    func testWebImportReportsFailureReasons() async throws {
        let db = try TestSupport.makeDatabase()
        let web = WebImporter(database: db, fetch: fakeFetch { request in
            let path = request.url?.path ?? ""
            if path == "/missing" {
                return (404, [:], Data())
            }
            return (200, ["Content-Type": "image/png"], Data([0x89, 0x50]))
        })

        let notFound = await web.importWebPage(url: URL(string: "https://example.com/missing")!)
        guard case .failure(let reason404) = notFound else { return XCTFail("got \(notFound)") }
        XCTAssertTrue(reason404.contains("404"))

        let binary = await web.importWebPage(url: URL(string: "https://example.com/pic")!)
        guard case .failure(let reasonMime) = binary else { return XCTFail("got \(binary)") }
        XCTAssertTrue(reasonMime.contains("image/png"))

        let drafts = try await db.drafts()
        XCTAssertTrue(drafts.isEmpty) // 失败不产生草稿
    }

    // MARK: - GitHub 链接解析

    func testGitHubLinkParser() {
        XCTAssertEqual(
            GitHubLinkParser.parse("https://github.com/octocat/repo"),
            GitHubLinkParser.Ref(kind: .repo, owner: "octocat", repo: "repo"))
        XCTAssertEqual(
            GitHubLinkParser.parse("https://github.com/octocat/repo.git"),
            GitHubLinkParser.Ref(kind: .repo, owner: "octocat", repo: "repo"))
        XCTAssertEqual(
            GitHubLinkParser.parse("https://github.com/octocat/repo/blob/main/docs/notes/想法.md"),
            GitHubLinkParser.Ref(kind: .file, owner: "octocat", repo: "repo", ref: "main", path: "docs/notes/想法.md"))
        XCTAssertEqual(
            GitHubLinkParser.parse("https://github.com/octocat/repo/tree/dev/sub/dir"),
            GitHubLinkParser.Ref(kind: .repo, owner: "octocat", repo: "repo", ref: "dev", path: "sub/dir"))
        XCTAssertNil(GitHubLinkParser.parse("https://gitlab.com/a/b"))
        XCTAssertNil(GitHubLinkParser.parse("https://github.com/octocat/repo/wiki"))
        XCTAssertNil(GitHubLinkParser.parse("随便一段话"))
    }

    // MARK: - GitHub 客户端

    func testGitHubClientParsesTreeAndFlagsTruncation() async throws {
        let treeJSON = """
        {"sha": "treeshaa", "truncated": true, "tree": [
          {"path": "README.md", "type": "blob", "sha": "b1", "size": 100},
          {"path": "src", "type": "tree", "sha": "d1"},
          {"path": "notes/idea.txt", "type": "blob", "sha": "b2", "size": 50}
        ]}
        """
        let client = GitHubClient(fetch: fakeFetch { request in
            (200, [:], Data(treeJSON.utf8))
        })
        let result = try await client.listTree(owner: "o", repo: "r", ref: "main")
        XCTAssertEqual(result.treeSha, "treeshaa")
        XCTAssertTrue(result.truncated) // "列表不完整"标记（R-002）
        XCTAssertEqual(result.entries.count, 3) // 客户端返回原始树，blob 过滤由调用方负责
        XCTAssertEqual(result.entries[1].sha, "d1")
    }

    func testGitHubClientErrorMapping() async throws {
        let client = GitHubClient(fetch: fakeFetch { _ in (404, [:], Data()) })
        do {
            _ = try await client.defaultBranch(owner: "o", repo: "r")
            XCTFail("should throw")
        } catch let error as GitHubClient.GitHubError {
            XCTAssertEqual(error, .notFoundOrPrivate)
        }
        let limited = GitHubClient(fetch: fakeFetch { _ in
            (403, ["X-RateLimit-Remaining": "0"], Data())
        })
        do {
            _ = try await limited.defaultBranch(owner: "o", repo: "r")
            XCTFail("should throw")
        } catch let error as GitHubClient.GitHubError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    // MARK: - GitHub 导入

    private func githubRouter() -> GitHubClient.Fetch {
        fakeFetch { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://api.github.com/repos/octo/notes" {
                return (200, [:], Data(#"{"default_branch": "main"}"#.utf8))
            }
            if url.contains("/commits?path=") {
                return (200, [:], Data(#"[{"sha": "c0ffee"}]"#.utf8))
            }
            if url.hasPrefix("https://raw.githubusercontent.com/octo/notes/main/") {
                return (200, [:], Data("# GitHub 笔记\n\n来自仓库的正文。".utf8))
            }
            return (404, [:], Data())
        }
    }

    func testGitHubSingleFileImportRecordsVersionSha() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = GitHubImporter(database: db, snapshotsDirectory: workspace.snapshots,
                                      client: GitHubClient(fetch: githubRouter()))
        let ref = GitHubLinkParser.parse("https://github.com/octo/notes/blob/main/notes.md")!
        let outcome = await importer.importSingleFile(ref: ref)
        guard case .success(let draft) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertFalse(draft.isEditable)
        XCTAssertEqual(draft.title, "GitHub 笔记") // 标题来自一级标题
        XCTAssertEqual(draft.sourceVersionSha, "c0ffee") // 所读版本标识（R-002）
        XCTAssertEqual(draft.sourceLocation, "https://github.com/octo/notes/blob/main/notes.md")
        XCTAssertEqual(draft.sourceLabel, "octo/notes：notes.md")
        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 1)
    }

    func testGitHubRepoFileImportAndDuplicate() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = GitHubImporter(database: db, snapshotsDirectory: workspace.snapshots,
                                      client: GitHubClient(fetch: githubRouter()))
        let request = GitHubImportRequest(
            owner: "octo", repo: "notes", branch: "main", treeSha: "treeshaa",
            path: "docs/report.md", blobSha: "b1")
        let first = await importer.importFile(request: request)
        guard case .success(let draft) = first else { return XCTFail("got \(first)") }
        XCTAssertEqual(draft.sourceVersionSha, "treeshaa")
        XCTAssertEqual(draft.sourceType, .githubFile)

        let second = await importer.importFile(request: request)
        guard case .duplicate = second else { return XCTFail("got \(second)") }

        let allowed = await importer.importFile(request: request, allowDuplicate: true)
        guard case .success = allowed else { return XCTFail("got \(allowed)") }
        let all = try await db.drafts()
        XCTAssertEqual(all.count, 2)
    }

    func testGitHubImportRejectsUnsupportedFile() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = GitHubImporter(database: db, snapshotsDirectory: workspace.snapshots,
                                      client: GitHubClient(fetch: githubRouter()))
        let request = GitHubImportRequest(
            owner: "octo", repo: "notes", branch: "main", treeSha: "t",
            path: "binary/app.exe", blobSha: "b")
        let outcome = await importer.importFile(request: request)
        guard case .failure(let reason) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(reason.contains("app.exe"))
        let drafts = try await db.drafts()
        XCTAssertTrue(drafts.isEmpty)
    }

    // MARK: - 行级差异

    func testLineDiffBasicOperations() {
        let ops = LineDiff.diff("甲\n乙\n丙", "甲\n改乙\n丙\n丁")
        XCTAssertEqual(ops, [
            .same("甲"), .removed("乙"), .added("改乙"), .same("丙"), .added("丁"),
        ])
        XCTAssertTrue(LineDiff.hasChanges(ops))

        let same = LineDiff.diff("一行", "一行")
        XCTAssertEqual(same, [.same("一行")])
        XCTAssertFalse(LineDiff.hasChanges(same))
    }

    func testLineDiffFallsBackForOversizedText() {
        let hugeOld = Array(repeating: "旧", count: 3000).joined(separator: "\n")
        let hugeNew = Array(repeating: "新", count: 3000).joined(separator: "\n")
        let ops = LineDiff.diff(hugeOld, hugeNew)
        XCTAssertTrue(LineDiff.hasChanges(ops)) // 不崩溃、不丢内容
        XCTAssertEqual(ops.count, 6000)
    }
}
