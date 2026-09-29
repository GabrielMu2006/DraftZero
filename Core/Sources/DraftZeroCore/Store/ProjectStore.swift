import Foundation
import GRDB

/// 项目、标签与多项目归属（R-005/R-008）。
extension AppDatabase {

    // MARK: - 项目

    public func projects() async throws -> [Project] {
        try await pool.read { db in
            try Project.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    public func project(id: UUID) async throws -> Project? {
        try await pool.read { db in
            try Project.fetchOne(db, key: id)
        }
    }

    /// 桌面组件数据（R-009）：TODO 项目 + 最近项目（与 TODO 去重，排除封存）。
    public func widgetProjects(todoLimit: Int = 2, recentLimit: Int = 3) async throws
        -> (todo: [(id: UUID, name: String)], recent: [(id: UUID, name: String)]) {
        try await pool.read { db in
            let all = try Project.order(Column("createdAt").desc).fetchAll(db)
            let todo = all.filter { $0.status == .todo }.prefix(todoLimit)
            let todoIds = Set(todo.map(\.id))
            let recent = all
                .filter { !todoIds.contains($0.id) && $0.status != .archived }
                .prefix(recentLimit)
            return (
                todo.map { ($0.id, $0.name) },
                recent.map { ($0.id, $0.name) }
            )
        }
    }

    /// 新项目默认"待整理"（R-008）。
    public func createProject(name: String) async throws -> Project {
        let project = Project(name: name)
        _ = try await pool.write { db in
            try project.insert(db)
        }
        return project
    }

    public func renameProject(id: UUID, name: String) async throws {
        try await pool.write { db in
            guard var project = try Project.fetchOne(db, key: id) else { return }
            project.name = name
            try project.update(db)
        }
    }

    /// 状态可任意切换，不改草稿正文或关系（R-008）。
    public func setProjectStatus(id: UUID, status: ProjectStatus) async throws {
        try await pool.write { db in
            guard var project = try Project.fetchOne(db, key: id) else { return }
            project.status = status
            try project.update(db)
        }
    }

    /// 删除项目保留草稿（R-005）：仍属于别的项目的继续留在那里，否则回到未归组区。
    public func deleteProject(id: UUID) async throws {
        try await pool.write { db in
            _ = try Project.filter(Column("id") == id).deleteAll(db)
        }
    }

    // MARK: - 归属

    @discardableResult
    public func addDraft(_ draftId: UUID, toProject projectId: UUID) async throws -> Bool {
        try await pool.write { db in
            guard try Draft.exists(db, key: draftId), try Project.exists(db, key: projectId) else { return false }
            if try ProjectDraft
                .filter(Column("projectId") == projectId && Column("draftId") == draftId)
                .fetchOne(db) != nil { return false }
            let membership = ProjectDraft(projectId: projectId, draftId: draftId)
            try membership.insert(db)
            return true
        }
    }

    /// 从其中一个项目移除不会让草稿从另一个项目消失（R-005）。
    @discardableResult
    public func removeDraft(_ draftId: UUID, fromProject projectId: UUID) async throws -> Bool {
        try await pool.write { db in
            _ = try ProjectDraft
                .filter(Column("projectId") == projectId && Column("draftId") == draftId)
                .deleteAll(db)
            return true
        }
    }

    public func drafts(inProject projectId: UUID) async throws -> [Draft] {
        try await pool.read { db in
            let sql = """
                SELECT draft.* FROM draft
                JOIN projectDraft ON projectDraft.draftId = draft.id
                WHERE projectDraft.projectId = ?
                ORDER BY draft.importedAt DESC
                """
            return try Draft.fetchAll(db, sql: sql, arguments: [projectId])
        }
    }

    public func projects(containing draftId: UUID) async throws -> [Project] {
        try await pool.read { db in
            let sql = """
                SELECT project.* FROM project
                JOIN projectDraft ON projectDraft.projectId = project.id
                WHERE projectDraft.draftId = ?
                ORDER BY project.createdAt ASC
                """
            return try Project.fetchAll(db, sql: sql, arguments: [draftId])
        }
    }

    /// 草稿卡片上的"所属项目数"。
    public func projectCountsByDraft() async throws -> [UUID: Int] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT draftId, COUNT(*) AS count FROM projectDraft GROUP BY draftId
                """)
            var result: [UUID: Int] = [:]
            for row in rows {
                if let id = row["draftId"] as UUID?, let count = row["count"] as Int? {
                    result[id] = count
                }
            }
            return result
        }
    }

    // MARK: - 标签（R-008）

    /// 同名标签不会重复创建（R-008 验收）。
    public func upsertTag(name: String) async throws -> Tag {
        try await pool.write { db in
            if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let tag = Tag(name: name)
            try tag.insert(db)
            return tag
        }
    }

    public func addTag(_ name: String, toProject projectId: UUID) async throws {
        try await pool.write { db in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                tag = existing
            } else {
                let created = Tag(name: name)
                try created.insert(db)
                tag = created
            }
            guard try Project.exists(db, key: projectId) else { return }
            if try ProjectTag
                .filter(Column("projectId") == projectId && Column("tagId") == tag.id)
                .fetchOne(db) != nil { return }
            try ProjectTag(projectId: projectId, tagId: tag.id).insert(db)
        }
    }

    public func removeTag(_ name: String, fromProject projectId: UUID) async throws {
        try await pool.write { db in
            guard let tag = try Tag.filter(Column("name") == name).fetchOne(db) else { return }
            _ = try ProjectTag
                .filter(Column("projectId") == projectId && Column("tagId") == tag.id)
                .deleteAll(db)
        }
    }

    public func tags(onProject projectId: UUID) async throws -> [Tag] {
        try await pool.read { db in
            let sql = """
                SELECT tag.* FROM tag
                JOIN projectTag ON projectTag.tagId = tag.id
                WHERE projectTag.projectId = ?
                ORDER BY tag.name ASC
                """
            return try Tag.fetchAll(db, sql: sql, arguments: [projectId])
        }
    }

    public func projects(withTag name: String) async throws -> [Project] {
        try await pool.read { db in
            let sql = """
                SELECT project.* FROM project
                JOIN projectTag ON projectTag.projectId = project.id
                JOIN tag ON tag.id = projectTag.tagId
                WHERE tag.name = ?
                ORDER BY project.createdAt ASC
                """
            return try Project.fetchAll(db, sql: sql, arguments: [name])
        }
    }
}
