import XCTest
@testable import DraftZeroCore

/// R-001/R-006/R-011 数据层验收：新建、编辑、版本、删除。
final class StoreTests: XCTestCase {

    func testFreshMigrationAndEmptyWorkspace() async throws {
        let db = try TestSupport.makeDatabase()
        let drafts = try await db.drafts()
        XCTAssertTrue(drafts.isEmpty)
        let projects = try await db.projects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testCreateManualDraftStoresInitialVersion() async throws {
        let db = try TestSupport.makeDatabase()
        let draft = try await db.createManualDraft(title: "想法", content: "第一段内容")
        XCTAssertEqual(draft.sourceType, .manual)
        XCTAssertTrue(draft.isEditable)

        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.origin, .initial)
        XCTAssertEqual(versions.first?.content, "第一段内容")
    }

    func testVersionOnlyRecordedWhenContentChanged() async throws {
        let db = try TestSupport.makeDatabase()
        let draft = try await db.createManualDraft(title: "t", content: "v1")

        try await db.updateDraftContent(id: draft.id, content: "v2")
        try await db.recordVersionIfChanged(draftId: draft.id, content: "v2", origin: .autoSave)
        // 无实际变化不产生重复版本
        try await db.recordVersionIfChanged(draftId: draft.id, content: "v2", origin: .autoSave)

        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.map(\.content), ["v2", "v1"]) // 最新在前
    }

    func testRestoreCreatesNewVersionAndKeepsHistory() async throws {
        let db = try TestSupport.makeDatabase()
        let draft = try await db.createManualDraft(title: "t", content: "第一版")
        try await db.updateDraftContent(id: draft.id, content: "第二版")
        try await db.recordVersionIfChanged(draftId: draft.id, content: "第二版", origin: .autoSave)

        let history = try await db.versions(draftId: draft.id)
        XCTAssertEqual(history.count, 2)
        let firstVersion = history.last! // 最早版本

        let restored = try await db.restoreVersion(versionId: firstVersion.id)
        XCTAssertEqual(restored?.content, "第一版")

        let after = try await db.versions(draftId: draft.id)
        XCTAssertEqual(after.count, 3) // 恢复产生新版本，历史不丢
        XCTAssertEqual(after.first?.origin, .restore)
        XCTAssertEqual(after.first?.content, "第一版")
    }

    func testDeleteDraftRemovesContentAndVersionsButKeepsRelationRow() async throws {
        let db = try TestSupport.makeDatabase()
        let source = try await db.createManualDraft(title: "源", content: "正文")
        let target = try await db.createManualDraft(title: "目标", content: "另一份")
        let relation = EvolutionRelation(sourceDraftId: source.id, targetDraftId: target.id, type: .reinterpret, note: "同一主题")
        _ = try await db.pool.write { db in try relation.insert(db) }

        try await db.deleteDraft(id: source.id)

        let drafts = try await db.drafts().map(\.id)
        XCTAssertFalse(drafts.contains(source.id))
        XCTAssertTrue(drafts.contains(target.id)) // 其他草稿仍可用（R-011）
        let versions = try await db.versions(draftId: source.id)
        XCTAssertTrue(versions.isEmpty) // 正文与版本移除
        let relations = try await db.relations(draftId: target.id)
        XCTAssertEqual(relations.count, 1) // 关系行保留 → 界面显示"来源已删除"
        XCTAssertEqual(relations.first?.sourceDraftId, source.id)
        XCTAssertEqual(relations.first?.note, "同一主题")
    }

    func testDerivedDraftKeepsSourceRelation() async throws {
        let db = try TestSupport.makeDatabase()
        let snapshot = try await db.createManualDraft(title: "网页快照", content: "快照内容")
        // 模拟只读快照
        try await db.pool.write { db in
            var d = try Draft.fetchOne(db, key: snapshot.id)!
            d.isEditable = false
            try d.update(db)
        }

        let derived = try await db.createDerivedDraft(from: snapshot.id, title: nil, content: "快照内容")
        XCTAssertEqual(derived?.isEditable, true)
        XCTAssertEqual(derived?.sourceType, .derived)

        let relations = try await db.relations(draftId: derived!.id)
        XCTAssertEqual(relations.first?.type, .derived)
        XCTAssertEqual(relations.first?.sourceDraftId, snapshot.id)

        try await db.updateRelationNote(id: relations.first!.id, note: "改写说明")
        let updated = try await db.relations(draftId: derived!.id)
        XCTAssertEqual(updated.first?.note, "改写说明")
    }
}
