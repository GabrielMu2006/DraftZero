import Foundation
import GRDB

/// 草稿：应用内文本副本或只读来源快照（SPEC §5）。
/// 文本内容直接存库；PDF 等二进制快照存盘，snapshotFileURL 指向容器内路径。
public struct Draft: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var title: String
    /// 应用内正文；PDF 无可选中文字时为 nil 或空。
    public var content: String?
    public var isEditable: Bool
    /// 扫描版 PDF 为 false，界面须显示"无可用于关联的文字"。
    public var hasExtractableText: Bool
    public var sourceType: SourceType
    /// 原路径或 URL；应用内新建草稿为 nil。
    public var sourceLocation: String?
    /// 界面展示的来源名（文件名/域名/仓库路径）。
    public var sourceLabel: String?
    /// 二进制快照在应用容器内的绝对路径。
    public var snapshotFileURL: String?
    /// 归一化正文 SHA-256，用于重复来源提示（不作为归组依据）。
    public var fingerprint: String?
    /// 外部快照所读版本的标识：GitHub 为 tree/commit SHA（R-002），网页/PDF 为 nil。
    public var sourceVersionSha: String?
    public var importedAt: Date

    public static let databaseTableName = "draft"

    public init(
        id: UUID = UUID(),
        title: String,
        content: String?,
        isEditable: Bool,
        hasExtractableText: Bool = true,
        sourceType: SourceType,
        sourceLocation: String? = nil,
        sourceLabel: String? = nil,
        snapshotFileURL: String? = nil,
        fingerprint: String? = nil,
        sourceVersionSha: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEditable = isEditable
        self.hasExtractableText = hasExtractableText
        self.sourceType = sourceType
        self.sourceLocation = sourceLocation
        self.sourceLabel = sourceLabel
        self.snapshotFileURL = snapshotFileURL
        self.fingerprint = fingerprint
        self.sourceVersionSha = sourceVersionSha
        self.importedAt = importedAt
    }
}

/// 文本版本（R-006）。恢复旧版会产生 origin=.restore 的新版本，历史不删除。
public struct DraftVersion: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var draftId: UUID
    public var content: String
    public var origin: VersionOrigin
    public var createdAt: Date

    public static let databaseTableName = "draftVersion"

    public init(id: UUID = UUID(), draftId: UUID, content: String, origin: VersionOrigin, createdAt: Date = Date()) {
        self.id = id
        self.draftId = draftId
        self.content = content
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// 演化关系（R-007）。来源草稿被删除后本行保留，界面显示"来源已删除"（R-011）。
public struct EvolutionRelation: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var sourceDraftId: UUID
    public var targetDraftId: UUID
    public var type: RelationType
    /// "重新解释"等关系的短说明（R-007），可修改或移除。
    public var note: String?
    public var createdAt: Date

    public static let databaseTableName = "evolutionRelation"

    public init(
        id: UUID = UUID(),
        sourceDraftId: UUID,
        targetDraftId: UUID,
        type: RelationType,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceDraftId = sourceDraftId
        self.targetDraftId = targetDraftId
        self.type = type
        self.note = note
        self.createdAt = createdAt
    }
}
