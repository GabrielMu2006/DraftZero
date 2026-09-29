import XCTest
import GRDB
@testable import DraftZeroCore

/// R-010 数据层验收：提供方解析、引用校验、错误映射、Key 不入日志/请求体不含路径。
final class RemoteAnalysisTests: XCTestCase {

    private static let draftA = (id: UUID(), title: "评测想法", text: "想给大模型做分级评测任务集，第一档考检索转述。包含足够长的正文以通过引用校验的测试。")
    private static let draftB = (id: UUID(), title: "评分 prompt", text: "判分员只依据任务说明打分，输出 JSON 并引用原文。同样的评测体系下的判分提示词。")

    private final class BodyBox: @unchecked Sendable {
        var data: Data?
    }

    private static func fakeFetch(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> DeepSeekProvider.Fetch {
        { request in
            let (status, body) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private static func chatBody(content: String) -> Data {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return Data(#"{"choices":[{"message":{"content":\#(escaped)}}]}"#.utf8)
    }

    func testAnalyzeReturnsValidatedProposals() async throws {
        let payload = """
        {"groups":[{"draft_ids":[0,1],"reason":"同一评测体系","citations":[
            {"draft_index":0,"quote":"第一档考检索转述"},
            {"draft_index":1,"quote":"这段引文并不存在于草稿里abcdefg"},
            {"draft_index":1,"quote":"判分员只依据任务说明打分"}]},
          {"draft_ids":[0],"reason":"单草稿组应被丢弃","citations":[{"draft_index":0,"quote":"第一档考检索转述"}]}]}
        """
        let box = BodyBox()
        let provider = DeepSeekProvider(apiKey: "sk-test", fetch: Self.fakeFetch { request in
            box.data = request.httpBody
            return (200, Self.chatBody(content: payload))
        })

        let (proposals, notice) = try await provider.analyzeProjectCandidates(
            drafts: [Self.draftA, Self.draftB])

        // 请求体绝不含本机路径（R-010）
        let bodyText = String(data: box.data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains("/Users/"))
        XCTAssertFalse(bodyText.contains("sourceLocation"))

        XCTAssertEqual(proposals.count, 1) // 单草稿组被丢弃
        XCTAssertEqual(proposals[0].draftIds.count, 2)
        XCTAssertEqual(proposals[0].citations.count, 2) // 编造的引用被剔除
        XCTAssertNil(notice) // 短文本未截断
    }

    func testAnalyzeReportsTruncationNotice() async throws {
        let longDraft = (id: UUID(), title: "长文", text: String(repeating: "长", count: 3000))
        let provider = DeepSeekProvider(apiKey: "sk-test", fetch: Self.fakeFetch { _ in
            (200, Self.chatBody(content: #"{"groups":[]}"#))
        })
        let (_, notice) = try await provider.analyzeProjectCandidates(drafts: [longDraft, Self.draftB])
        XCTAssertNotNil(notice) // R-010：超出限制时说明仅分析了部分文字
        XCTAssertTrue(notice?.contains("1500") ?? false)
    }

    func testErrorMapping() async {
        for (status, expected) in [(401, RemoteAnalysisError.invalidKey),
                                   (402, RemoteAnalysisError.paymentRequired),
                                   (429, RemoteAnalysisError.rateLimited),
                                   (500, RemoteAnalysisError.serverError(code: 500))] {
            let provider = DeepSeekProvider(apiKey: "sk", fetch: Self.fakeFetch { _ in (status, Data()) })
            do {
                _ = try await provider.analyzeProjectCandidates(drafts: [Self.draftA, Self.draftB])
                XCTFail("should throw for \(status)")
            } catch let error as RemoteAnalysisError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error type \(error)")
            }
        }
    }

    func testQuoteMatchingIgnoresPunctuationAndRequiresLength() {
        XCTAssertTrue(DeepSeekProvider.quoteMatches("大模型做分级评测，任务集！", in: Self.draftA.text)) // 标点不影响、长度达标
        // 模型截短引文：引用前 20 个归一化字符命中原文即认可
        let extendedQuote = String(Self.draftA.text.prefix(26)) + "，然后模型自己续写的内容不算数"
        XCTAssertTrue(DeepSeekProvider.quoteMatches(extendedQuote, in: Self.draftA.text))
        XCTAssertFalse(DeepSeekProvider.quoteMatches("短引", in: Self.draftA.text)) // 过短无证据价值
        XCTAssertFalse(DeepSeekProvider.quoteMatches("完全不同的引文内容不存在于此", in: Self.draftA.text))
    }

    func testParseStripsCodeFences() throws {
        let fenced = "```json\n{\"groups\":[{\"draft_ids\":[0,1],\"reason\":\"r\",\"citations\":[]}]}\n```"
        let payload = try DeepSeekProvider.parseGroupsPayload(from: fenced)
        XCTAssertEqual(payload.groups.first?.draft_ids, [0, 1])
        XCTAssertThrowsError(try DeepSeekProvider.parseGroupsPayload(from: "不是 JSON"))
    }

    func testSuggestionStoreRoundtripAndDismiss() async throws {
        let db = try TestSupport.makeDatabase()
        let suggestion = RemoteSuggestion(
            provider: "deepseek", model: "deepseek-chat",
            draftIdsData: try JSONEncoder().encode([Self.draftA.id, Self.draftB.id]),
            explanation: "同一评测体系",
            citationsData: try JSONEncoder().encode([RemoteCitation(draftId: Self.draftA.id, quote: "分级评测任务集")]))
        try await db.saveRemoteSuggestion(suggestion)

        var pending = try await db.pendingRemoteSuggestions(provider: "deepseek")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.draftIds, [Self.draftA.id, Self.draftB.id])
        XCTAssertEqual(pending.first?.citations.first?.quote, "分级评测任务集")

        try await db.dismissRemoteSuggestion(id: suggestion.id)
        pending = try await db.pendingRemoteSuggestions(provider: "deepseek")
        XCTAssertTrue(pending.isEmpty)
    }
}
