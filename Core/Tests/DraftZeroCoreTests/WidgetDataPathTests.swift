import XCTest
import GRDB
@testable import DraftZeroCore

/// 收尾方案 P4：桌面组件扩展的数据路径回归。
/// Widget 时间线用裸 SQL + `row["id"] as UUID?` 解码（Widget/DraftZeroWidget.swift），
/// 两个 AppIntent 走 `setProjectStatus`。这些行为必须有单测锁定。
final class WidgetDataPathTests: XCTestCase {

    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase(pool: DatabaseQueue())
    }

    func testWidgetTimelineSQLDecodesBlobUUID() async throws {
        let p1 = try await database.createProject(name: "组件待办")
        try await database.setProjectStatus(id: p1.id, status: .todo)
        let p2 = try await database.createProject(name: "组件最近")
        try await database.setProjectStatus(id: p2.id, status: .inProgress)

        try await database.pool.read { db in
            // Widget 时间线 TODO 查询（与 DraftZeroWidget.readProjectsEntry 相同）
            let todoRows = try Row.fetchAll(
                db, sql: "SELECT id, name FROM project WHERE status = ? ORDER BY createdAt DESC LIMIT 2",
                arguments: [ProjectStatus.todo.rawValue])
            XCTAssertEqual(todoRows.count, 1)
            let todoId: UUID? = todoRows.first?["id"] as UUID?
            XCTAssertEqual(todoId, p1.id, "裸 SQL 的 blob UUID 必须能用 `as UUID?` 解码（组件时间线依赖）")

            // 最近项目查询：排除封存，去重 TODO
            let recentRows = try Row.fetchAll(
                db, sql: "SELECT id, name FROM project WHERE status != ? ORDER BY createdAt DESC LIMIT 4",
                arguments: [ProjectStatus.archived.rawValue])
            let todoIds = Set(todoRows.compactMap { $0["id"] as UUID? })
            let recent = recentRows.compactMap { row -> UUID? in
                guard let id = row["id"] as UUID?, !todoIds.contains(id) else { return nil }
                return id
            }
            XCTAssertEqual(recent, [p2.id])
        }
    }

    func testIntentWritePathChangesStatus() async throws {
        let project = try await database.createProject(name: "意图写入")
        try await database.setProjectStatus(id: project.id, status: .todo)

        // MarkProjectDoneIntent：todo → mostlyDone
        try await database.setProjectStatus(id: project.id, status: .mostlyDone)
        var stored = try await database.projects().first { $0.id == project.id }
        XCTAssertEqual(stored?.status, .mostlyDone)

        // MarkProjectTodoIntent：→ todo
        try await database.setProjectStatus(id: project.id, status: .todo)
        stored = try await database.projects().first { $0.id == project.id }
        XCTAssertEqual(stored?.status, .todo)
    }
}
