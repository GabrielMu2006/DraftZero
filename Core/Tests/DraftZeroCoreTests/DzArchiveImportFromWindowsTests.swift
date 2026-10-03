import XCTest
import GRDB
@testable import DraftZeroCore

/// D-002 双向迁移：导入 Windows 导出的 .dzarchive（fixture 由 C# 导出测试生成）。
final class DzArchiveImportFromWindowsTests: XCTestCase {

    private var workspace: (root: URL, snapshots: URL)!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        workspace = try TestSupport.makeWorkspace()
        database = try AppDatabase(pool: DatabaseQueue(path: workspace.root.appendingPathComponent("dz.sqlite").path))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: workspace.root)
    }

    private var windowsFixtureURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../Windows/tests/DraftZero.Core.Tests/Fixtures/migration/sample-win.dzarchive")
    }

    /// M-01/M-02/M-03：Windows 档案 → Mac 空库，计数/正文/PDF 重绑/裁决全保留。
    func testImportWindowsArchiveIntoEmptyWorkspace() async throws {
        let counts = try await DzArchiveImporter.importArchive(
            archivePath: windowsFixtureURL.path,
            into: database, snapshotsDirectory: workspace.snapshots)

        XCTAssertEqual(counts.drafts, 3)
        XCTAssertEqual(counts.projects, 1)
        XCTAssertEqual(counts.tags, 1)
        XCTAssertEqual(counts.pdfSnapshots, 1)
        XCTAssertEqual(counts.candidateDecisions, 1)

        // 抽样正文
        let drafts = try await database.drafts()
        let base = try XCTUnwrap(drafts.first { $0.title == "基准测试想法" })
        XCTAssertTrue(base.content?.contains("讨论任务集与评分口径") ?? false)

        // PDF 重绑到 Mac snapshots
        let pdf = try XCTUnwrap(drafts.first { $0.sourceType == .pdf })
        XCTAssertTrue(pdf.hasExtractableText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.snapshotFileURL ?? ""))
        XCTAssertTrue(pdf.snapshotFileURL?.hasPrefix(workspace.snapshots.path) ?? false)

        // 成员关系
        let projects = try await database.projects()
        XCTAssertEqual(projects.count, 1)
        let members = try await database.drafts(inProject: projects[0].id)
        XCTAssertEqual(members.count, 1)

        // 裁决保留（抑制规则依赖）
        let rejected = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM candidatePair WHERE status = 'rejected'")
        }
        XCTAssertEqual(rejected, 1)
    }

    /// 非空工作区拒绝导入（不做自动合并）。
    func testImportRejectsNonEmptyWorkspace() async throws {
        _ = try await database.createManualDraft(title: "已有", content: "已有内容。")
        do {
            _ = try await DzArchiveImporter.importArchive(
                archivePath: windowsFixtureURL.path,
                into: database, snapshotsDirectory: workspace.snapshots)
            XCTFail("非空工作区应拒绝导入")
        } catch let error as DzArchiveImporter.ImportError {
            XCTAssertTrue(error.localizedDescription.contains("空工作区"))
        }
        // 零部分写入
        let drafts = try await database.drafts()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.title, "已有")
    }

    /// 损坏档案：SHA 校验失败，零部分写入。
    func testImportTamperedArchiveFailsCleanly() async throws {
        let data = try Data(contentsOf: windowsFixtureURL)
        var bytes = [UInt8](data)
        bytes[bytes.count / 2] ^= 0xFF
        let tampered = workspace.root.appendingPathComponent("tampered.dzarchive")
        try Data(bytes).write(to: tampered)

        do {
            _ = try await DzArchiveImporter.importArchive(
                archivePath: tampered.path,
                into: database, snapshotsDirectory: workspace.snapshots)
            XCTFail("损坏档案应导入失败")
        } catch {
            // 期望路径：SHA 校验或解压失败
        }
        let empty = try await DzArchiveImporter.isWorkspaceEmpty(database)
        XCTAssertTrue(empty, "失败后主库必须仍是空库（零部分写入）")
    }
}
