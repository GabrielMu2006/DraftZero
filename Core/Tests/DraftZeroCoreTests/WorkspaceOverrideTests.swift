import XCTest
import GRDB
@testable import DraftZeroCore

/// 收尾方案 P4：主应用与桌面组件共享的库定位规则。
/// 覆盖 `DZ_WORKSPACE_DIR` 时，`defaultDatabaseURL()` 与
/// `defaultSnapshotsURL()` 都必须落在隔离目录（组件扩展走同一实现）；
/// 未设置时回落默认路径，用户日常库不受影响。
final class WorkspaceOverrideTests: XCTestCase {

    private func withOverride<T>(_ dir: URL, _ body: () throws -> T) rethrows -> T {
        setenv("DZ_WORKSPACE_DIR", dir.path, 1)
        defer { unsetenv("DZ_WORKSPACE_DIR") }
        return try body()
    }

    func testOverrideDirectoryIsHonoredByDatabaseAndSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DZOverride-\(UUID().uuidString)", isDirectory: true)
        try withOverride(dir) {
            let db = AppDatabase.defaultDatabaseURL()
            XCTAssertEqual(db.lastPathComponent, "DraftZero.sqlite")
            XCTAssertEqual(db.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)

            let snapshots = AppDatabase.defaultSnapshotsURL()
            XCTAssertEqual(snapshots.lastPathComponent, "snapshots")
            XCTAssertEqual(snapshots.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)

            // 隔离目录内的库可以正常打开与建表（组件/主应用都能用的同一实现）。
            let database = try AppDatabase(pool: DatabasePool(path: db.path))
            let one = try database.pool.read { db -> Int in
                try Int.fetchOne(db, sql: "SELECT 1") ?? 0
            }
            XCTAssertEqual(one, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testUnsetOverrideFallsBackToDefaultPath() throws {
        unsetenv("DZ_WORKSPACE_DIR")
        XCTAssertNil(AppDatabase.workspaceDirectoryOverride())
        // Debug 构建默认回落 Application Support 的传统位置（与组件一致），
        // 断言不落在临时目录即说明未误用覆盖。
        let db = AppDatabase.defaultDatabaseURL()
        XCTAssertFalse(db.path.hasPrefix("/var/folders") || db.path.hasPrefix("/tmp"),
                       "无覆盖时不应落到临时目录：\(db.path)")
    }
}
