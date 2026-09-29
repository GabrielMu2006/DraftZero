import Foundation
import GRDB

/// 草稿与版本查询（T-001/T-003）。所有方法异步走写队列/读队列。
extension AppDatabase {

    // MARK: - 草稿

    public func drafts() async throws -> [Draft] {
        try await pool.read { db in
            try Draft.order(Column("importedAt").desc).fetchAll(db)
        }
    }

    public func draft(id: UUID) async throws -> Draft? {
        try await pool.read { db in
            try Draft.fetchOne(db, key: id)
        }
    }

    /// 重复来源检测（SPEC §6）：同一路径或同一归一化指纹都算已有快照。
    /// 指纹可命中"文件名不同但内容相同"的重复。
    func findExistingDraft(sourceLocation: String?, fingerprint: String?) async throws -> Draft? {
        try await pool.read { db in
            if let location = sourceLocation,
               let hit = try Draft.filter(Column("sourceLocation") == location).fetchOne(db) {
                return hit
            }
            if let fingerprint,
               let hit = try Draft.filter(Column("fingerprint") == fingerprint).fetchOne(db) {
                return hit
            }
            return nil
        }
    }

    func insertDraft(_ draft: Draft, initialVersion: Bool) async throws -> Draft {
        try await pool.write { db in
            var draft = draft
            try draft.insert(db)
            if initialVersion, let content = draft.content {
                let version = DraftVersion(draftId: draft.id, content: content, origin: .initial)
                try version.insert(db)
            }
            return draft
        }
    }

    /// 应用内新建文本草稿（R-001）。
    public func createManualDraft(title: String, content: String) async throws -> Draft {
        try await insertDraft(
            Draft(title: title.isEmpty ? "未命名草稿" : title, content: content,
                  isEditable: true, sourceType: .manual),
            initialVersion: true)
    }

    /// 更新可编辑草稿正文；版本化由 AutoVersioner/调用方走 recordVersionIfChanged。
    public func updateDraftContent(id: UUID, content: String) async throws {
        try await pool.write { db in
            guard var draft = try Draft.fetchOne(db, key: id) else { return }
            draft.content = content
            try draft.update(db)
        }
    }

    public func updateDraftTitle(id: UUID, title: String) async throws {
        try await pool.write { db in
            guard var draft = try Draft.fetchOne(db, key: id) else { return }
            draft.title = title
            try draft.update(db)
        }
    }

    /// 删除草稿（R-011）：移除正文与版本（级联）；演化关系行保留，
    /// 存续草稿的来路显示"来源已删除"。二进制快照文件由调用方清理。
    public func deleteDraft(id: UUID) async throws {
        try await pool.write { db in
            _ = try ProjectDraft.filter(Column("draftId") == id).deleteAll(db)
            _ = try Draft.filter(Column("id") == id).deleteAll(db)
        }
    }

    // MARK: - 版本（R-006）

    public func versions(draftId: UUID) async throws -> [DraftVersion] {
        try await pool.read { db in
            try DraftVersion
                .filter(Column("draftId") == draftId)
                .order(Column("createdAt").desc, Column("rowid").desc) // 同刻时间戳按插入序兜底
                .fetchAll(db)
        }
    }

    /// 每份草稿最近一次版本时间（"最近编辑"排序用；无版本草稿由调用方回退 importedAt）。
    public func lastEditedByDraft() async throws -> [UUID: Date] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT draftId, MAX(createdAt) AS latest FROM draftVersion GROUP BY draftId")
            var result: [UUID: Date] = [:]
            for row in rows {
                guard let id: UUID = row["draftId"], let date: Date = row["latest"] else { continue }
                result[id] = date
            }
            return result
        }
    }

    /// 无实际文本变化不产生重复版本（R-006 验收）。
    public func recordVersionIfChanged(draftId: UUID, content: String, origin: VersionOrigin) async throws {
        try await pool.write { db in
            let last = try DraftVersion
                .filter(Column("draftId") == draftId)
                .order(Column("createdAt").desc, Column("rowid").desc)
                .fetchOne(db)
            guard last?.content != content else { return }
            let version = DraftVersion(draftId: draftId, content: content, origin: origin)
            try version.insert(db)
        }
    }

    /// 恢复旧版：产生 origin=.restore 的新版本，不抹掉中间历史（R-006）。
    public func restoreVersion(versionId: UUID) async throws -> Draft? {
        try await pool.write { db in
            guard let version = try DraftVersion.fetchOne(db, key: versionId) else { return nil }
            guard var draft = try Draft.fetchOne(db, key: version.draftId) else { return nil }
            draft.content = version.content
            try draft.update(db)
            let restore = DraftVersion(draftId: draft.id, content: version.content, origin: .restore)
            try restore.insert(db)
            return draft
        }
    }

    // MARK: - 演化关系（R-003/R-007 基础）

    /// 从只读快照或既有草稿衍生新的可编辑草稿，保留"源自"关系（R-003）。
    public func createDerivedDraft(from sourceDraftId: UUID, title: String?, content: String) async throws -> Draft? {
        try await pool.write { db in
            guard let source = try Draft.fetchOne(db, key: sourceDraftId) else { return nil }
            let draft = Draft(
                title: title ?? source.title + "（副本）",
                content: content,
                isEditable: true,
                sourceType: .derived)
            try draft.insert(db)
            let version = DraftVersion(draftId: draft.id, content: content, origin: .initial)
            try version.insert(db)
            let relation = EvolutionRelation(sourceDraftId: source.id, targetDraftId: draft.id, type: .derived)
            try relation.insert(db)
            return draft
        }
    }

    /// 拆分（R-007）：把草稿中的一段文字生成为新草稿；源草稿内容不变，双向可追溯。
    public func splitDraft(sourceId: UUID, piece: String, offsetInSource: Int, newTitle: String?) async throws -> Draft? {
        try await pool.write { db in
            guard let source = try Draft.fetchOne(db, key: sourceId) else { return nil }
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let draft = Draft(
                title: newTitle ?? TextReading.extractTitle(from: piece, fallback: source.title + "（拆分）"),
                content: trimmed,
                isEditable: true,
                sourceType: .derived)
            try draft.insert(db)
            try DraftVersion(draftId: draft.id, content: trimmed, origin: .initial).insert(db)
            try EvolutionRelation(
                sourceDraftId: source.id, targetDraftId: draft.id, type: .split,
                note: "拆分自第 \(offsetInSource) 字符处").insert(db)
            return draft
        }
    }

    /// 合并（R-007）：两份及以上文本草稿按指定顺序合成新的可编辑草稿；来源不变。
    public func mergeDrafts(ids: [UUID], title: String?) async throws -> Draft? {
        try await pool.write { db in
            guard ids.count >= 2 else { return nil }
            var sources: [Draft] = []
            for id in ids {
                guard let draft = try Draft.fetchOne(db, key: id) else { return nil }
                sources.append(draft)
            }
            let joined = sources.map { $0.content ?? "" }.joined(separator: "\n\n")
            let draft = Draft(
                title: title ?? "合并：" + sources.first.map { String($0.title.prefix(12)) }! + " 等",
                content: joined,
                isEditable: true,
                sourceType: .derived)
            try draft.insert(db)
            try DraftVersion(draftId: draft.id, content: joined, origin: .merge).insert(db)
            for source in sources {
                try EvolutionRelation(
                    sourceDraftId: source.id, targetDraftId: draft.id, type: .merge).insert(db)
            }
            return draft
        }
    }

    public func relations(draftId: UUID) async throws -> [EvolutionRelation] {
        try await pool.read { db in
            try EvolutionRelation
                .filter(Column("sourceDraftId") == draftId || Column("targetDraftId") == draftId)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// 关系说明可修改或移除（R-007 验收）。
    public func updateRelationNote(id: UUID, note: String?) async throws {
        try await pool.write { db in
            guard var relation = try EvolutionRelation.fetchOne(db, key: id) else { return }
            relation.note = note
            try relation.update(db)
        }
    }
}
