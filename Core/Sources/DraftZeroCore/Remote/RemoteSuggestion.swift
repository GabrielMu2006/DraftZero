import Foundation
import GRDB

/// 远程分析的建议（R-010）：仅作建议，不自动确认归类；
/// 引用必须逐字来自草稿原文才允许展示为依据。
public struct RemoteSuggestion: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var provider: String
    public var model: String?
    /// JSON 编码的 [UUID]：建议同组的草稿。
    public var draftIdsData: Data?
    public var explanation: String?
    /// JSON 编码的 [RemoteCitation]，已通过原文校验。
    public var citationsData: Data?
    /// 截断等服务限制说明（R-010"仅分析了部分文字"）。
    public var notice: String?
    public var createdAt: Date
    public var dismissed: Bool

    public static let databaseTableName = "remoteSuggestion"

    public init(
        id: UUID = UUID(), provider: String, model: String? = nil,
        draftIdsData: Data? = nil, explanation: String? = nil,
        citationsData: Data? = nil, notice: String? = nil,
        createdAt: Date = Date(), dismissed: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.draftIdsData = draftIdsData
        self.explanation = explanation
        self.citationsData = citationsData
        self.notice = notice
        self.createdAt = createdAt
        self.dismissed = dismissed
    }

    public var draftIds: [UUID] {
        guard let data = draftIdsData else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }

    public var citations: [RemoteCitation] {
        guard let data = citationsData else { return [] }
        return (try? JSONDecoder().decode([RemoteCitation].self, from: data)) ?? []
    }
}

/// 引用片段：远程结果要展示为依据，必须先通过原文校验。
public struct RemoteCitation: Codable, Sendable, Hashable {
    public var draftId: UUID
    public var quote: String

    public init(draftId: UUID, quote: String) {
        self.draftId = draftId
        self.quote = quote
    }
}

/// 提供方返回的分组提案（解析与校验的中间产物）。
public struct RemoteGroupProposal: Sendable, Equatable {
    public var draftIds: [UUID]
    public var reason: String
    public var citations: [RemoteCitation]

    public init(draftIds: [UUID], reason: String, citations: [RemoteCitation]) {
        self.draftIds = draftIds
        self.reason = reason
        self.citations = citations
    }
}

/// 远程分析的抽象（R-010：V1 只提供 DeepSeek，但保留替换提供方的能力）。
public protocol RemoteAnalysisProvider: Sendable {
    var identifier: String { get }
    /// drafts 的 text 只含草稿正文与标题；绝不上传本机路径或原始文件。
    func analyzeProjectCandidates(
        drafts: [(id: UUID, title: String, text: String)]
    ) async throws -> (proposals: [RemoteGroupProposal], notice: String?)
}

public enum RemoteAnalysisError: LocalizedError, Equatable {
    case invalidKey
    case paymentRequired
    case rateLimited
    case serverUnreachable(String)
    case serverError(code: Int)
    case badResponse
    case disabled

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "API Key 无效，请检查设置"
        case .paymentRequired: "DeepSeek 账户余额不足，请充值后重试"
        case .rateLimited: "请求过于频繁或触发限流，请稍后重试"
        case .serverUnreachable(let detail): "网络错误，无法连接远程服务：\(detail)"
        case .serverError(let code): "远程服务出错（HTTP \(code)），请稍后重试"
        case .badResponse: "远程服务返回了无法解析的结果"
        case .disabled: "远程分析未启用"
        }
    }
}
