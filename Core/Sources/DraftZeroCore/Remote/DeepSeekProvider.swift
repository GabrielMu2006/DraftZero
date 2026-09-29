import Foundation

/// DeepSeek 提供方（R-010）。只发送标题与正文节选，绝不上传原始文件或本机路径；
/// 网络层可注入以便离线测试。
public struct DeepSeekProvider: Sendable {

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let defaultEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    /// 模型名会随服务方变化（SPEC §7），不写成永久产品规则；调用方可覆盖。
    public let model: String
    public let endpoint: URL
    public let apiKey: String
    public let fetch: Fetch

    /// 每份草稿正文节选上限与总预算（R-010"超出服务限制时说明仅分析了部分文字"）。
    public static let perDraftCharacterLimit = 1500
    public static let totalCharacterBudget = 12000

    public init(
        apiKey: String, model: String = "deepseek-chat",
        endpoint: URL = DeepSeekProvider.defaultEndpoint, fetch: Fetch? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: HTTPUserAgent.stamped(request))
            guard let http = response as? HTTPURLResponse else {
                throw RemoteAnalysisError.serverUnreachable("无有效响应")
            }
            return (data, http)
        }
    }

    public var identifier: String { "deepseek" }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    struct ChatRequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let response_format: ResponseFormat
    }

    struct ResponseFormat: Encodable { let type: String }

    struct GroupsPayload: Decodable {
        struct Group: Decodable {
            struct Citation: Decodable {
                let draft_index: Int
                let quote: String
            }
            let draft_ids: [Int]
            let reason: String?
            let citations: [Citation]?
        }
        let groups: [Group]
    }

    // MARK: - 提示词

    static let systemPrompt = """
    你是草稿归类助手。仅依据给出的草稿文本判断哪些草稿可能属于同一个想法项目。输出 JSON：\
    {"groups":[{"draft_ids":[编号],"reason":"一句话理由","citations":[{"draft_index":编号,"quote":"原文片段"}]}]}。\
    规则：1) 编号必须是给出的草稿编号；2) 每条 quote 必须逐字摘自对应草稿原文；\
    3) 证据不足就不要分组；4) 不要编造共同关键词或因果关系；5) 不要输出 JSON 以外的内容。
    """

    func userPrompt(drafts: [(id: UUID, title: String, text: String)]) -> (prompt: String, truncated: Bool) {
        var budget = Self.totalCharacterBudget
        var truncated = false
        var lines: [String] = []
        for (index, draft) in drafts.enumerated() {
            var body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > Self.perDraftCharacterLimit {
                body = String(body.prefix(Self.perDraftCharacterLimit))
                truncated = true
            }
            if body.count > budget {
                body = String(body.prefix(max(0, budget)))
                truncated = true
            }
            budget -= body.count
            lines.append("草稿 \(index)：\(draft.title)\n\(body)")
        }
        return ("以下是待分析的草稿：\n\n" + lines.joined(separator: "\n\n") + "\n\n请给出可能的分组。", truncated)
    }

    // MARK: - 分析

    public func analyzeProjectCandidates(
        drafts: [(id: UUID, title: String, text: String)]
    ) async throws -> (proposals: [RemoteGroupProposal], notice: String?) {
        guard drafts.count >= 2 else {
            return ([], nil) // 单份草稿没有可分组对象
        }
        let (prompt, truncated) = userPrompt(drafts: drafts)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequestBody(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: prompt),
            ],
            temperature: 0.2,
            response_format: .init(type: "json_object"))
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw RemoteAnalysisError.serverUnreachable(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw RemoteAnalysisError.invalidKey
        case 402: throw RemoteAnalysisError.paymentRequired
        case 429: throw RemoteAnalysisError.rateLimited
        case 400...499: throw RemoteAnalysisError.serverError(code: response.statusCode)
        default: throw RemoteAnalysisError.serverError(code: response.statusCode)
        }

        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = chat.choices.first?.message.content else {
            throw RemoteAnalysisError.badResponse
        }
        let payload = try Self.parseGroupsPayload(from: content)

        let idByIndex = drafts.map(\.id)
        let contents = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.text) })
        var proposals: [RemoteGroupProposal] = []
        for group in payload.groups {
            let ids = group.draft_ids.compactMap { index in
                index >= 0 && index < idByIndex.count ? idByIndex[index] : nil
            }
            guard ids.count >= 2 else { continue } // 单草稿"分组"没有意义
            // 引用校验：quote 必须能在对应草稿原文（归一化后）中找到，否则丢弃该引用；
            // 一条有效引用都没有的分组不展示（R-010：必须引用实际草稿片段才能展示为依据）。
            let validCitations = (group.citations ?? []).compactMap { citation -> RemoteCitation? in
                guard citation.draft_index >= 0, citation.draft_index < idByIndex.count else { return nil }
                let draftId = idByIndex[citation.draft_index]
                let text = contents[draftId] ?? ""
                return Self.quoteMatches(citation.quote, in: text)
                    ? RemoteCitation(draftId: draftId, quote: citation.quote)
                    : nil
            }
            guard !validCitations.isEmpty else { continue }
            proposals.append(RemoteGroupProposal(
                draftIds: Array(Set(ids)),
                reason: group.reason ?? "",
                citations: validCitations))
        }

        let notice: String? = truncated ? "草稿较长，仅发送了每个草稿的前 \(Self.perDraftCharacterLimit) 字参与分析" : nil
        return (proposals, notice)
    }

    /// 模型输出可能带 ```json 围栏，剥离后再解析；解析失败视为 badResponse。
    static func parseGroupsPayload(from content: String) throws -> GroupsPayload {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            var body = json.drop(while: { $0 != "\n" }).dropFirst()
            while body.last == "`" { body = body.dropLast() }
            json = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GroupsPayload.self, from: data) else {
            throw RemoteAnalysisError.badResponse
        }
        return payload
    }

    /// 引用校验：归一化后取子串；模型偶尔会截短引文，回退为前缀匹配。
    public static func quoteMatches(_ quote: String, in text: String) -> Bool {
        func normalize(_ s: String) -> String {
            String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
                .map(String.init).joined().lowercased()
        }
        let nQuote = normalize(quote)
        let nText = normalize(text)
        guard nQuote.count >= 8 else { return false } // 过短的"引用"没有证据价值
        if nText.contains(nQuote) { return true }
        let prefix = String(nQuote.prefix(min(nQuote.count, 20)))
        return nText.contains(prefix)
    }
}
