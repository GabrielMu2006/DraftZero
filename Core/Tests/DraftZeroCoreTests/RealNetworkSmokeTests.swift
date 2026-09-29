import XCTest
import GRDB
@testable import DraftZeroCore

/// 真实网络冒烟（默认跳过）：DZ_NET_TEST=1 swift test --filter RealNetworkSmoke
/// 用于在代理可用时验证 R-002 的端到端路径。不写入正式验收证据。
final class RealNetworkSmokeTests: XCTestCase {

    func testImportExampleComPage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DZ_NET_TEST"] == "1")
        let db = try AppDatabase(pool: DatabaseQueue())
        let web = WebImporter(database: db)
        let outcome = await web.importWebPage(url: URL(string: "https://example.com")!)
        guard case .success(let draft) = outcome else {
            return XCTFail("example.com import failed: \(outcome)")
        }
        XCTAssertEqual(draft.sourceType, .web)
        XCTAssertEqual(draft.sourceLocation, "https://example.com")
        XCTAssertTrue(draft.content?.contains("Example") ?? false)
    }

    func testImportGitHubSingleFile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DZ_NET_TEST"] == "1")
        let db = try AppDatabase(pool: DatabaseQueue())
        let importer = GitHubImporter(
            database: db,
            snapshotsDirectory: FileManager.default.temporaryDirectory)
        guard let ref = GitHubLinkParser.parse(
            "https://github.com/octocat/Hello-World/blob/master/README") else {
            return XCTFail("parse failed")
        }
        let outcome = await importer.importSingleFile(ref: ref)
        guard case .success(let draft) = outcome else {
            return XCTFail("github import failed: \(outcome)")
        }
        XCTAssertEqual(draft.sourceType, .githubFile)
        XCTAssertNotNil(draft.sourceVersionSha)
        XCTAssertTrue(draft.content?.contains("Hello World") ?? false)
    }
}
