import XCTest
@testable import DraftZeroCore

/// R-007 数据层验收：拆分、合并、来路可追溯、来源删除后的表现。
final class SplitMergeTests: XCTestCase {

    func testSplitKeepsSourceIntactAndRecordsRelation() async throws {
        let db = try TestSupport.makeDatabase()
        let source = try await db.createManualDraft(title: "长想法", content: "第一段讲背景。\n\n第二段讲方案，值得单独成稿。\n\n第三段讲后续。")
        let originalContent = source.content

        let piece = "第二段讲方案，值得单独成稿。"
        let offset = try XCTUnwrap(source.content?.range(of: piece)?.lowerBound.utf16Offset(in: source.content!))
        let split = try await db.splitDraft(sourceId: source.id, piece: piece, offsetInSource: offset, newTitle: "方案稿")

        let splitDraft = try XCTUnwrap(split)
        XCTAssertEqual(splitDraft.title, "方案稿")
        XCTAssertEqual(splitDraft.content, piece)
        XCTAssertTrue(splitDraft.isEditable)

        let reloaded = try await db.draft(id: source.id)
        XCTAssertEqual(reloaded?.content, originalContent) // 源草稿内容不变（A-003）

        let relations = try await db.relations(draftId: splitDraft.id)
        XCTAssertEqual(relations.first?.type, .split)
        XCTAssertEqual(relations.first?.sourceDraftId, source.id) // 双向可追溯

        let versions = try await db.versions(draftId: splitDraft.id)
        XCTAssertEqual(versions.count, 1)
    }

    func testSplitWithDefaultTitleUsesPiece() async throws {
        let db = try TestSupport.makeDatabase()
        let source = try await db.createManualDraft(title: "来源", content: "开头。\n\n# 独立小节\n这一节值得拆出去展开写，内容足够长。")
        let split = try await db.splitDraft(
            sourceId: source.id, piece: "# 独立小节\n这一节值得拆出去展开写，内容足够长。",
            offsetInSource: 4, newTitle: nil)
        XCTAssertEqual(split?.title, "独立小节") // 默认标题取自片段的一级标题
    }

    func testMergeJoinsInGivenOrderAndSourcesUnchanged() async throws {
        let db = try TestSupport.makeDatabase()
        let a = try await db.createManualDraft(title: "甲", content: "甲的内容。")
        let b = try await db.createManualDraft(title: "乙", content: "乙的内容。")

        let merged = try await db.mergeDrafts(ids: [a.id, b.id], title: "合成稿")
        let mergedDraft = try XCTUnwrap(merged)
        XCTAssertEqual(mergedDraft.content, "甲的内容。\n\n乙的内容。") // 指定顺序
        XCTAssertEqual(mergedDraft.isEditable, true)

        let aReloaded = try await db.draft(id: a.id)
        let bReloaded = try await db.draft(id: b.id)
        XCTAssertEqual(aReloaded?.content, "甲的内容。") // 来源不删除不覆盖
        XCTAssertEqual(bReloaded?.content, "乙的内容。")

        let relations = try await db.relations(draftId: mergedDraft.id)
        XCTAssertEqual(relations.count, 2)
        XCTAssertEqual(Set(relations.map(\.type)), Set([.merge]))
        XCTAssertEqual(Set(relations.map(\.sourceDraftId)), Set([a.id, b.id]))
    }

    func testMergeRequiresTwoSources() async throws {
        let db = try TestSupport.makeDatabase()
        let a = try await db.createManualDraft(title: "甲", content: "只有一份。")
        let merged = try await db.mergeDrafts(ids: [a.id], title: nil)
        XCTAssertNil(merged)
    }

    func testDeletingSplitSourceShowsSourceDeletedSemantics() async throws {
        let db = try TestSupport.makeDatabase()
        let source = try await db.createManualDraft(title: "源", content: "正文内容，包含足够长的文字用于拆分测试，这部分将被拆出去。")
        let split = try await db.splitDraft(sourceId: source.id, piece: "这部分将被拆出去。", offsetInSource: 26, newTitle: nil)

        try await db.deleteDraft(id: source.id) // R-011：删除来源

        let relations = try await db.relations(draftId: split!.id)
        XCTAssertEqual(relations.count, 1) // 关系行保留
        let stillThere = try await db.draft(id: split!.id)
        XCTAssertEqual(stillThere?.content, "这部分将被拆出去。") // 存续草稿仍可用
    }
}
