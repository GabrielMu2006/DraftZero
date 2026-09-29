import Foundation
import GRDB

/// 想法项目（R-005/R-008）。删除项目不删除草稿。
public struct Project: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var name: String
    public var notes: String?
    public var status: ProjectStatus
    public var createdAt: Date

    public static let databaseTableName = "project"

    public init(id: UUID = UUID(), name: String, notes: String? = nil, status: ProjectStatus = .inbox, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.status = status
        self.createdAt = createdAt
    }
}

/// 自由主题标签（R-008），名称唯一。
public struct Tag: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var name: String

    public static let databaseTableName = "tag"

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct ProjectTag: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var projectId: UUID
    public var tagId: UUID

    public static let databaseTableName = "projectTag"

    public init(projectId: UUID, tagId: UUID) {
        self.projectId = projectId
        self.tagId = tagId
    }
}

/// 草稿与项目的多对多归属（R-005）：一份草稿可属于多个项目，内容只有一份。
public struct ProjectDraft: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var projectId: UUID
    public var draftId: UUID

    public static let databaseTableName = "projectDraft"

    public init(projectId: UUID, draftId: UUID) {
        self.projectId = projectId
        self.draftId = draftId
    }
}
