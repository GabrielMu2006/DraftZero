import XCTest
@testable import DraftZeroCore

/// R-005/R-008 数据层验收：多项目归属、删除项目保留草稿、状态与标签。
final class ProjectStoreTests: XCTestCase {

    func testDraftCanBelongToTwoProjectsWithSingleContent() async throws {
        let db = try TestSupport.makeDatabase()
        let draft = try await db.createManualDraft(title: "共享草稿", content: "唯一内容")
        let p1 = try await db.createProject(name: "项目一")
        let p2 = try await db.createProject(name: "项目二")

        try await db.addDraft(draft.id, toProject: p1.id)
        try await db.addDraft(draft.id, toProject: p2.id)
        try await db.addDraft(draft.id, toProject: p1.id) // 重复加入幂等

        let inP1 = try await db.drafts(inProject: p1.id)
        let inP2 = try await db.drafts(inProject: p2.id)
        XCTAssertEqual(inP1.map(\.id), [draft.id])
        XCTAssertEqual(inP2.map(\.id), [draft.id])

        try await db.updateDraftContent(id: draft.id, content: "编辑后的内容")
        let reread1 = try await db.drafts(inProject: p1.id).first
        let reread2 = try await db.drafts(inProject: p2.id).first
        XCTAssertEqual(reread1?.content, "编辑后的内容") // 两处打开同一最新内容
        XCTAssertEqual(reread2?.content, "编辑后的内容")

        try await db.removeDraft(draft.id, fromProject: p1.id)
        let afterRemove = try await db.projects(containing: draft.id).map(\.id)
        XCTAssertEqual(afterRemove, [p2.id]) // 从一个项目移除不影响另一个
        let stillThere = try await db.drafts()
        XCTAssertEqual(stillThere.map(\.id), [draft.id]) // 移除归属不删草稿
    }

    func testDeleteProjectKeepsDrafts() async throws {
        let db = try TestSupport.makeDatabase()
        let shared = try await db.createManualDraft(title: "共享", content: "")
        let lonely = try await db.createManualDraft(title: "孤单", content: "")
        let p1 = try await db.createProject(name: "会被删除")
        let p2 = try await db.createProject(name: "继续存在")
        try await db.addDraft(shared.id, toProject: p1.id)
        try await db.addDraft(shared.id, toProject: p2.id)
        try await db.addDraft(lonely.id, toProject: p1.id)

        try await db.deleteProject(id: p1.id)

        let all = try await db.drafts().map(\.title).sorted()
        XCTAssertEqual(all, ["共享", "孤单"]) // 删除项目保留草稿（R-005）
        let sharedProjects = try await db.projects(containing: shared.id).map(\.id)
        XCTAssertEqual(sharedProjects, [p2.id])
        let lonelyProjects = try await db.projects(containing: lonely.id)
        XCTAssertTrue(lonelyProjects.isEmpty) // 回到未归组区
    }

    func testProjectDefaultsToInboxAndStatusIsSwitchable() async throws {
        let db = try TestSupport.makeDatabase()
        let project = try await db.createProject(name: "新项目")
        XCTAssertEqual(project.status, .inbox) // 默认待整理（R-008）

        try await db.setProjectStatus(id: project.id, status: .todo)
        var reloaded = try await db.projects().first
        XCTAssertEqual(reloaded?.status, .todo)

        try await db.setProjectStatus(id: project.id, status: .archived)
        reloaded = try await db.projects().first
        XCTAssertEqual(reloaded?.status, .archived) // 封存可切换（可逆状态）
    }

    func testTagsAreUniqueAndFilterable() async throws {
        let db = try TestSupport.makeDatabase()
        let p1 = try await db.createProject(name: "A")
        let p2 = try await db.createProject(name: "B")

        let tag1 = try await db.upsertTag(name: "长文")
        let tag2 = try await db.upsertTag(name: "长文") // 同名不重复创建（R-008）
        XCTAssertEqual(tag1.id, tag2.id)

        try await db.addTag("长文", toProject: p1.id)
        try await db.addTag("长文", toProject: p1.id) // 重复添加幂等
        try await db.addTag("长文", toProject: p2.id)

        let onP1 = try await db.tags(onProject: p1.id).map(\.name)
        XCTAssertEqual(onP1, ["长文"])
        let withTag = try await db.projects(withTag: "长文").map(\.id)
        XCTAssertEqual(Set(withTag), Set([p1.id, p2.id]))

        try await db.removeTag("长文", fromProject: p2.id)
        let afterRemove = try await db.projects(withTag: "长文").map(\.id)
        XCTAssertEqual(afterRemove, [p1.id])
    }

    func testProjectCountsByDraft() async throws {
        let db = try TestSupport.makeDatabase()
        let d1 = try await db.createManualDraft(title: "d1", content: "")
        let d2 = try await db.createManualDraft(title: "d2", content: "")
        let p = try await db.createProject(name: "p")
        try await db.addDraft(d1.id, toProject: p.id)

        let counts = try await db.projectCountsByDraft()
        XCTAssertEqual(counts[d1.id], 1)
        XCTAssertNil(counts[d2.id])
    }
}
