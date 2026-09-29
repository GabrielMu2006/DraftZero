import XCTest
import GRDB
@testable import DraftZeroCore

/// V0.1.0：App Group 化迁移（组件扩展沙盒化后，共享数据必须进 Group 容器）。
/// 迁移只应由主应用调用一次；规则见 AppDatabase.migrateLegacyWorkspaceIfNeeded。
final class WorkspaceMigrationTests: XCTestCase {

    private func makeWorkspace(
        at dir: URL, draftCount: Int = 0, snapshotFileURL: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("DraftZero.sqlite").path)
        _ = try AppDatabase(pool: pool)
        for index in 0..<draftCount {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO draft
                        (id, title, content, isEditable, hasExtractableText,
                         sourceType, snapshotFileURL, importedAt)
                    VALUES (?, ?, NULL, 1, 1, 'manual', ?, datetime('now'))
                    """, arguments: [UUID(), "草稿\(index)", snapshotFileURL])
            }
        }
        return dir
    }

    private var markerURL: URL { group.appendingPathComponent(".migrated-from-app-support-v1") }
    private let group = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DZMig-group-\(UUID().uuidString)", isDirectory: true)
    private let legacy = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DZMig-legacy-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: group)
        try? FileManager.default.removeItem(at: legacy)
    }

    func testFreshInstallWritesMarkerWithoutMigration() throws {
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let result = AppDatabase.migrateLegacyWorkspaceIfNeeded(groupDir: group, legacyDir: legacy)
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: group.appendingPathComponent("DraftZero.sqlite").path))
    }

    func testMigratesDatabaseSnapshotsAndRelocatesPaths() throws {
        try makeWorkspace(at: legacy, draftCount: 1)
        let snapshotName = "\(UUID().uuidString).pdf"
        let legacySnapshots = legacy.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: legacySnapshots, withIntermediateDirectories: true)
        try Data("pdf-bytes".utf8).write(to: legacySnapshots.appendingPathComponent(snapshotName))
        let oldSnapshotPath = legacySnapshots.appendingPathComponent(snapshotName).path
        _ = try makeWorkspace(at: legacy, draftCount: 1, snapshotFileURL: oldSnapshotPath)

        let result = AppDatabase.migrateLegacyWorkspaceIfNeeded(groupDir: group, legacyDir: legacy)
        let migration = try XCTUnwrap(result)
        XCTAssertEqual(migration.snapshotsOldPrefix, legacySnapshots.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        // 库与快照都到了新位置；记录的绝对路径仍是旧前缀，等 relocate 修正。
        let pool = try DatabasePool(path: group.appendingPathComponent("DraftZero.sqlite").path)
        let count = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM draft") }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: group.appendingPathComponent("snapshots/\(snapshotName)").path))
        let stalePath = try pool.read {
            try String.fetchOne($0, sql: "SELECT snapshotFileURL FROM draft WHERE snapshotFileURL IS NOT NULL")
        }
        XCTAssertEqual(stalePath, oldSnapshotPath)

        let db = try AppDatabase(pool: pool)
        try awaitRelocate(db, migration: migration)
        let updated = try pool.read {
            try String.fetchOne($0, sql: "SELECT snapshotFileURL FROM draft WHERE snapshotFileURL IS NOT NULL")
        }
        XCTAssertEqual(
            updated,
            migration.snapshotsNewPrefix + "/\(snapshotName)")
    }

    /// relocateSnapshotPaths 是 async；包一层同步等待。
    private func awaitRelocate(_ db: AppDatabase, migration: AppDatabase.LegacyWorkspaceMigration) throws {
        let expectation = expectation(description: "relocate")
        Task {
            try? await db.relocateSnapshotPaths(
                from: migration.snapshotsOldPrefix, to: migration.snapshotsNewPrefix)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testSetAsideEmptyGroupDatabaseThenMigrate() throws {
        try makeWorkspace(at: legacy, draftCount: 1)
        // 目标预建空库（组件扩展/旧试验会这样留下 schema-only 的库）。
        try makeWorkspace(at: group, draftCount: 0)

        let migration = AppDatabase.migrateLegacyWorkspaceIfNeeded(groupDir: group, legacyDir: legacy)
        XCTAssertNotNil(migration)

        let fm = FileManager.default
        let leftovers = try fm.contentsOfDirectory(atPath: group.path)
            .filter {
                $0.hasPrefix("DraftZero.sqlite.pre-migration-")
                    && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm")
            }
        XCTAssertEqual(leftovers.count, 1, "空库应留档而非覆盖或删除")

        let pool = try DatabasePool(path: group.appendingPathComponent("DraftZero.sqlite").path)
        let count = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM draft") }
        XCTAssertEqual(count, 1, "旧库草稿应已迁入")
    }

    func testPopulatedGroupDatabaseStopsMigration() throws {
        try makeWorkspace(at: legacy, draftCount: 1)
        try makeWorkspace(at: group, draftCount: 2)

        let result = AppDatabase.migrateLegacyWorkspaceIfNeeded(groupDir: group, legacyDir: legacy)
        XCTAssertNil(result, "目标已有用户数据时不得迁移覆盖")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "异常态不写完成标记")

        let pool = try DatabasePool(path: group.appendingPathComponent("DraftZero.sqlite").path)
        let count = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM draft") }
        XCTAssertEqual(count, 2, "已有数据保持原样")
    }
}
