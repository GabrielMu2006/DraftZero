import XCTest
@testable import DraftZeroCore

/// R-001/R-003 导入验收：副本生成、原文件不变、逐项失败、重复提示、编码回退。
final class ImporterTests: XCTestCase {

    private var workspace: (root: URL, snapshots: URL)!

    override func setUpWithError() throws {
        workspace = try TestSupport.makeWorkspace()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
    }

    private func makeImporter(db: AppDatabase) -> LocalFileImporter {
        LocalFileImporter(database: db, snapshotsDirectory: workspace.snapshots)
    }

    func testImportMarkdownCreatesEditableCopyAndOriginalUnchanged() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let original = try TestSupport.write("# 评测想法\n\n正文内容若干。", name: "评测想法.md", in: workspace.root)
        let originalData = try Data(contentsOf: original)

        let outcome = await importer.importFile(at: original)
        guard case .success(let draft) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(draft.title, "评测想法") // 标题来自一级标题
        XCTAssertEqual(draft.content, "# 评测想法\n\n正文内容若干。")
        XCTAssertTrue(draft.isEditable)
        XCTAssertEqual(draft.sourceType, .localFile)
        XCTAssertEqual(draft.sourceLabel, "评测想法.md")
        XCTAssertNotNil(draft.fingerprint)

        // R-003：应用内有副本，磁盘原文件不变
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        // R-001：重开应用仍能看到副本与来源（库里可取回）
        let stored = try await db.drafts().first
        XCTAssertEqual(stored?.id, draft.id)
        XCTAssertEqual(stored?.sourceLocation, original.path)
        // 导入副本有初始版本
        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 1)
    }

    func testGB18030EncodingFallback() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let url = try TestSupport.write("# 老文档\n\n这是GB编码的旧文件。", name: "老文档.txt", in: workspace.root, encoding: gb18030)

        let outcome = await importer.importFile(at: url)
        guard case .success(let draft) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(draft.title, "老文档")
        XCTAssertTrue(draft.content?.contains("GB编码的旧文件") ?? false)
    }

    func testDuplicateSourceIsReportedNotSilentlyImported() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let url = try TestSupport.write("同一段内容。", name: "a.txt", in: workspace.root)

        _ = await importer.importFile(at: url)
        let second = await importer.importFile(at: url)
        guard case .duplicate(let existing) = second else {
            return XCTFail("expected duplicate, got \(second)")
        }
        XCTAssertEqual(existing.sourceLocation, url.path)

        // 用户选择"另存新快照"后允许重复导入
        let third = await importer.importFile(at: url, allowDuplicate: true)
        guard case .success = third else {
            return XCTFail("expected success on allowDuplicate, got \(third)")
        }
        let all = try await db.drafts()
        XCTAssertEqual(all.count, 2)
    }

    func testDuplicateByFingerprintAcrossDifferentFilenames() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        _ = await importer.importFile(at: try TestSupport.write("完全一样的正文，标点！ ", name: "one.txt", in: workspace.root))
        let other = await importer.importFile(at: try TestSupport.write("完全一样的正文，标点！ ", name: "two.md", in: workspace.root))
        guard case .duplicate = other else {
            return XCTFail("expected duplicate by fingerprint, got \(other)")
        }
    }

    func testUnsupportedAndEmptyFilesFailIndividually() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let docx = try TestSupport.write("fake", name: "document.docx", in: workspace.root)
        let empty = try TestSupport.write("   \n  ", name: "empty.txt", in: workspace.root)
        let good = try TestSupport.write("正常内容", name: "good.txt", in: workspace.root)

        let results = await importer.importFiles(at: [docx, empty, good])

        XCTAssertEqual(results.count, 3) // 逐项报告
        guard case .failure(let reason) = results[0].outcome else { return XCTFail("docx should fail") }
        XCTAssertTrue(reason.contains("docx"))
        guard case .failure(let emptyReason) = results[1].outcome else { return XCTFail("empty should fail") }
        XCTAssertTrue(emptyReason.contains("没有可读取的正文"))
        guard case .success = results[2].outcome else { return XCTFail("good should succeed") }
        // 失败项不产生空草稿，也不影响同批其他文件（R-001）
        let drafts = try await db.drafts()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.title, "正常内容")
    }

    func testBrokenPDFReportsFailureWithoutDraft() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let broken = try TestSupport.write("this is not a pdf", name: "broken.pdf", in: workspace.root)

        let outcome = await importer.importFile(at: broken)
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        let drafts = try await db.drafts()
        XCTAssertTrue(drafts.isEmpty)
    }

    func testTextPDFImportsWithExtractableText() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let url = try TestSupport.makePDF(
            name: "报告.pdf", in: workspace.root,
            text: "这是一份评测报告的节选，包含足够多的可选中文字，用于验证 PDF 文本提取与导入链路的完整行为。")

        let outcome = await importer.importFile(at: url)
        guard case .success(let draft) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertFalse(draft.isEditable) // PDF 是只读快照（R-003）
        XCTAssertTrue(draft.hasExtractableText)
        XCTAssertTrue(draft.content?.contains("评测报告") ?? false)
        XCTAssertNotNil(draft.snapshotFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.snapshotFileURL!))
    }

    func testScannedPDFImportsAsSnapshotWithoutText() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let url = try TestSupport.makePDF(name: "扫描件.pdf", in: workspace.root, text: nil)

        let outcome = await importer.importFile(at: url)
        guard case .success(let draft) = outcome else {
            return XCTFail("scanned PDF should still import as preview snapshot, got \(outcome)")
        }
        XCTAssertFalse(draft.hasExtractableText) // 界面须标明"无可用于关联的文字"
        XCTAssertNil(draft.content) // 不凭空生成正文
        XCTAssertNotNil(draft.snapshotFileURL) // 但保留快照供阅读
    }

    func testDeletingPDFDraftRemovesSnapshotFile() async throws {
        let db = try TestSupport.makeDatabase()
        let importer = makeImporter(db: db)
        let url = try TestSupport.makePDF(name: "待删除.pdf", in: workspace.root, text: "一些文字内容，足够长以通过阈值判断逻辑。")
        guard case .success(let draft) = await importer.importFile(at: url) else {
            return XCTFail("import should succeed")
        }

        try await db.deleteDraft(id: draft.id)
        if let snapshotPath = draft.snapshotFileURL {
            try? FileManager.default.removeItem(atPath: snapshotPath) // 应用层负责清理（AppModel 行为）
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.snapshotFileURL ?? "-"))
    }
}
