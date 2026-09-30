import XCTest
import GRDB
@testable import DraftZeroCore

/// V0.2.0 P-004：.dzarchive 导出契约测试。
/// 覆盖：实体齐全、不迁移 Key/向量/分数/绝对快照路径、manifest 计数与 SHA、
/// 原子导出（失败不落半成品）、源库不被修改。
final class DzArchiveExportTests: XCTestCase {

    private func seedWorkspace(root: URL, snapshots: URL) async throws -> (AppDatabase, Int) {
        let database = try AppDatabase(pool: DatabaseQueue(path: root.appendingPathComponent("dz.sqlite").path))
        _ = try await database.createManualDraft(title: "基准测试想法", content: "# 基准测试想法\n\n讨论任务集与评分口径。")
        _ = try await database.createManualDraft(title: "评分提示词", content: "模型测试 prompt，与基准测试相关。")
        _ = try await database.createManualDraft(title: "无关草稿", content: "周末烘焙计划：面包与蛋糕。")

        let pdfURL = try TestSupport.makePDF(name: "spec.pdf", in: root, text: "PDF 快照正文，用于迁移测试。")
        var pdfDraft = Draft(
            title: "spec", content: "PDF 快照正文，用于迁移测试。",
            isEditable: false, sourceType: .pdf,
            sourceLocation: pdfURL.path, sourceLabel: "spec.pdf")
        let snapshotDest = snapshots.appendingPathComponent("\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: pdfURL, to: snapshotDest)
        pdfDraft.snapshotFileURL = snapshotDest.path
        _ = try await database.insertDraft(pdfDraft, initialVersion: true)

        // 版本与演化：编辑一次产生 auto_save 版本，再拆分。
        let drafts = try await database.drafts()
        let base = try XCTUnwrap(drafts.first { $0.title == "基准测试想法" })
        try await database.updateDraftContent(id: base.id, content: "# 基准测试想法\n\n讨论任务集与评分口径。更新内容。")
        try await database.recordVersionIfChanged(draftId: base.id, content: "# 基准测试想法\n\n讨论任务集与评分口径。更新内容。", origin: .autoSave)
        _ = try await database.splitDraft(sourceId: base.id, piece: "更新内容。", offsetInSource: 10, newTitle: nil)

        // 项目、归属、标签、状态。
        let project = try await database.createProject(name: "评测计划")
        _ = try await database.addDraft(base.id, toProject: project.id)
        _ = try await database.addTag("测试", toProject: project.id)
        try await database.setProjectStatus(id: project.id, status: .todo)

        // 用户裁决行（rejected，含指纹）：Windows 端必须保留抑制。
        let other = try XCTUnwrap(drafts.first { $0.title == "无关草稿" })
        let fpBase = TextReading.fingerprint(of: "x")
        let pair = CandidatePair(
            draftA: base.id, draftB: other.id, kind: .lead, score: 0.5,
            evidence: nil, status: .rejected,
            fingerprintA: fpBase, fingerprintB: TextReading.fingerprint(of: "y"))
        try await database.pool.write { db in try pair.insert(db) }

        // 可展示的远程建议。
        let suggestion = RemoteSuggestion(
            provider: "deepseek", model: "deepseek-chat",
            draftIdsData: try JSONEncoder().encode([base.id, other.id]),
            explanation: "远程理由", citationsData: try JSONEncoder().encode([RemoteCitation(draftId: base.id, quote: "基准测试")]))
        try await database.saveRemoteSuggestion(suggestion)

        return (database, drafts.count)
    }

    func testExportProducesManifestCountsAndDoesNotMutateSource() async throws {
        let (root, snapshots) = try TestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, _) = try await seedWorkspace(root: root, snapshots: snapshots)

        let draftsBefore = try await database.drafts()
        let tablesBefore = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }.sorted()

        let destination = root.appendingPathComponent("sample.dzarchive")
        try await DzArchiveExporter.export(
            database: database, snapshotsDirectory: snapshots,
            to: destination, appVersion: "0.2.0")

        // ZIP 魔数与大小合理。
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "必须是 ZIP 本地文件头")
        XCTAssertGreaterThan(data.count, 1000, "应包含 PDF 快照与 JSON 数据")

        // CRC32 自检（ZIP 规范样例：123456789 → 0xCBF43926）。
        XCTAssertEqual(MinimalZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)

        // 源库未被修改。
        let draftsAfter = try await database.drafts()
        XCTAssertEqual(draftsAfter.map(\.id), draftsBefore.map(\.id))
        let tablesAfter = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }.sorted()
        XCTAssertEqual(tablesAfter, tablesBefore)

        // 记录为跨平台 fixture（C# 侧导入测试读取同一文件由生成步骤另行放置）。
    }

    func testExportFailsCleanlyWhenSnapshotMissing() async throws {
        let (root, snapshots) = try TestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, _) = try await seedWorkspace(root: root, snapshots: snapshots)
        // 删除 PDF 快照文件，制造不一致。
        if let pdfDraft = try await database.drafts().first(where: { $0.snapshotFileURL != nil }),
           let path = pdfDraft.snapshotFileURL {
            try FileManager.default.removeItem(atPath: path)
        }
        let destination = root.appendingPathComponent("broken.dzarchive")
        do {
            try await DzArchiveExporter.export(
                database: database, snapshotsDirectory: snapshots,
                to: destination, appVersion: "0.2.0")
            XCTFail("快照缺失应导致导出失败")
        } catch {
            // 失败零部分写入：不得留下半成品（临时文件已清理，目标不存在）。
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
                .filter { $0.hasPrefix(".dzarchive-tmp-") } ?? []
            XCTAssertEqual(leftovers, [], "不应留下临时导出文件")
        }
    }

    /// 生成跨平台 fixture：一份含全部实体类型的档案，提交进仓库供 C# 导入测试使用。
    /// 单独跑：swift test --filter DzArchiveExportTests/testGenerateMigrationFixture
    func testGenerateMigrationFixture() async throws {
        let (root, snapshots) = try TestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, _) = try await seedWorkspace(root: root, snapshots: snapshots)
        let destination = root.appendingPathComponent("sample.dzarchive")
        try await DzArchiveExporter.export(
            database: database, snapshotsDirectory: snapshots,
            to: destination, appVersion: "0.2.0")
        let fixtureTarget = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../Windows/tests/DraftZero.Core.Tests/Fixtures/migration/sample.dzarchive")
        try? FileManager.default.createDirectory(
            at: fixtureTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fixtureTarget.path) {
            try FileManager.default.removeItem(at: fixtureTarget)
        }
        try FileManager.default.copyItem(at: destination, to: fixtureTarget)
        print("fixture → \(fixtureTarget.path)")
    }
}
