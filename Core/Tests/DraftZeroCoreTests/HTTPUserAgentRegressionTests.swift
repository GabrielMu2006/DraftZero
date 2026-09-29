import XCTest
import Foundation
@testable import DraftZeroCore

/// 收尾方案 P5：显式 User-Agent 盖章回归（R-002 崩溃规避路径）。
/// 三个出站收口（WebImporter / GitHubClient / DeepSeekProvider）的**默认 fetch**
/// 都必须带 UA——本机 CFNetwork 默认 UA 初始化路径会崩溃（HTTPUserAgent.swift），
/// 注入式测试绕过了默认 fetch。这里用进程内 URLProtocol 拦截 URLSession.shared
/// 的真实出站请求，验证请求头与只读快照流程。
final class HTTPUserAgentRegressionTests: XCTestCase {

    /// 进程内请求拦截：记录所有请求头，按 host 返回固定响应。
    private final class RecordingURLProtocol: URLProtocol {
        static let lock = NSLock()
        nonisolated(unsafe) static var captured: [String: [String: String]] = [:] // path -> headers

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            captured = [:]
        }

        static func headers(ofPath path: String) -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            return captured[path] ?? [:]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? "/"
            var headers: [String: String] = [:]
            for (key, value) in request.allHTTPHeaderFields ?? [:] {
                headers[key.lowercased()] = value
            }
            Self.lock.lock()
            Self.captured[path] = headers
            Self.lock.unlock()

            let isDeepSeek = path.contains("chat/completions")
            let body: String = isDeepSeek
                ? #"{"choices":[{"message":{"content":"[]"}}]}"#
                : "<html><head><title>UA回归页</title></head><body><p>回归正文第一段，内容足够长以通过正文提取的最短长度检查，包含实际语句与细节描述。</p><p>回归正文第二段，继续补充更多语句与细节描述，确保提取器认定这是有效正文而不是导航或登录墙。</p></body></html>"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isDeepSeek ? "application/json" : "text/html; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        super.tearDown()
    }

    func testStampedAddsAndPreservesUserAgent() {
        let bare = URLRequest(url: URL(string: "https://example.com/x")!)
        XCTAssertNil(bare.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(HTTPUserAgent.stamped(bare).value(forHTTPHeaderField: "User-Agent"),
                       "DraftZero/0.1 (macOS)")
        var custom = URLRequest(url: URL(string: "https://example.com/y")!)
        custom.setValue("CustomAgent/9.9", forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(HTTPUserAgent.stamped(custom).value(forHTTPHeaderField: "User-Agent"),
                       "CustomAgent/9.9", "调用方已有的 UA 不得被覆盖")
    }

    /// 网页收口：默认 fetch（URLSession.shared）出站带 UA，且快照只读流程不受影响。
    func testWebImporterDefaultFetchSendsExplicitUA() async throws {
        let db = try TestSupport.makeDatabase()
        let web = WebImporter(database: db) // 默认 fetch
        let outcome = await web.importWebPage(url: URL(string: "https://ua-regression.example/page")!)
        guard case .success(let draft) = outcome else {
            return XCTFail("本地拦截下导入应成功：\(outcome)")
        }
        // R-003/R-002：只读快照 + 来源正确
        XCTAssertFalse(draft.isEditable)
        XCTAssertEqual(draft.sourceType, .web)
        XCTAssertEqual(draft.sourceLocation, "https://ua-regression.example/page")
        XCTAssertEqual(RecordingURLProtocol.headers(ofPath: "/page")["user-agent"],
                       "DraftZero/0.1 (macOS)", "网页请求必须带显式 UA（绕开 CFNetwork 默认 UA 崩溃路径）")
    }

    /// GitHub 收口：默认 fetch 带 UA 与 Accept；已设置的 UA 不被覆盖。
    func testGitHubClientDefaultFetchSendsUA() async throws {
        let client = GitHubClient() // 默认 fetch
        _ = try? await client.get(URL(string: "https://ua-regression.example/repos/x/y")!)
        let headers = RecordingURLProtocol.headers(ofPath: "/repos/x/y")
        XCTAssertEqual(headers["user-agent"], "DraftZero/0.1", "GitHubClient 自带显式 UA")
        XCTAssertEqual(headers["accept"], "application/vnd.github+json")
    }

    /// DeepSeek 收口：默认 fetch 带 UA 与鉴权头。
    func testDeepSeekDefaultFetchSendsExplicitUA() async throws {
        let provider = DeepSeekProvider(
            apiKey: "test-key",
            endpoint: URL(string: "https://ua-regression.example/chat/completions")!) // 默认 fetch
        _ = try? await provider.analyzeProjectCandidates(drafts: [
            (id: UUID(), title: "甲", text: "评估方案数据整理正文第一份草稿内容"),
            (id: UUID(), title: "乙", text: "评估方案数据整理正文第二份草稿内容")
        ])
        let headers = RecordingURLProtocol.headers(ofPath: "/chat/completions")
        XCTAssertEqual(headers["user-agent"], "DraftZero/0.1 (macOS)", "DeepSeek 请求必须带显式 UA")
        XCTAssertEqual(headers["authorization"], "Bearer test-key")
    }
}
