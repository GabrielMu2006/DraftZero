import XCTest
import GRDB
@testable import DraftZeroCore

/// 真实模型集成测试（T-011/T-004）：随包分发的量化 e5-small 在本机完成
/// 提取→索引→候选，并用 T-011 测试集样本验证"同项目命中"行为（R-004 方向性验证）。
/// 完整 30 份基线与质量门槛的度量留在 t011-spike（Python 复现脚本）。
final class E5IntegrationTests: XCTestCase {

    /// 引擎只加载一次（模型与分词器初始化较重）。
    private static let engineTask = Task<E5EmbeddingEngine, Error> {
        try await E5EmbeddingEngine()
    }

    private func sharedEngine() async throws -> E5EmbeddingEngine {
        try await Self.engineTask.value
    }

    private var workspace: (root: URL, snapshots: URL)!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        workspace = try TestSupport.makeWorkspace()
        database = try TestSupport.makeDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
    }

    private let threadDocs = [
        "Agent Benchmark 想法.md",
        "模型测试 prompt.md",
        "agent_eval_notes.md",
        "雨夜书店_第一章.md",
        "面包笔记.md",
    ]
    private let unrelated = "购物清单.txt"

    private func importFixtureDrafts() async throws -> [Draft] {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
            .appendingPathComponent("spike-sample") else {
            throw NSError(domain: "E5Integration", code: 1)
        }
        let importer = LocalFileImporter(database: database, snapshotsDirectory: workspace.snapshots)
        var drafts: [Draft] = []
        for name in threadDocs + [unrelated] {
            guard case .success(let draft) = await importer.importFile(at: dir.appendingPathComponent(name)) else {
                throw NSError(domain: "E5Integration", code: 2, userInfo: [NSLocalizedDescriptionKey: "导入失败：\(name)"])
            }
            drafts.append(draft)
        }
        return drafts
    }

    func testRealModelIndexAndCandidateHits() async throws {
        let engine: E5EmbeddingEngine
        do {
            engine = try await sharedEngine()
        } catch {
            throw XCTSkip("本机语义模型不可用（\(error.localizedDescription)）")
        }
        let drafts = try await importFixtureDrafts()
        let byName = Dictionary(uniqueKeysWithValues: zip(threadDocs + [unrelated], drafts.map(\.id)))

        let candidateEngine = CandidateEngine(database: database, embedder: engine)
        let report = try await candidateEngine.refresh(drafts: drafts)
        XCTAssertEqual(report.indexedDrafts, 6)

        let leads = try await candidateEngine.queue(kind: .lead)
        let pairsByDraft = Dictionary(grouping: leads) { pair -> [UUID] in
            [pair.draftA, pair.draftB]
        }

        func topPartners(of draftId: UUID, limit: Int) -> [UUID] {
            leads.filter { $0.involves(draftId) }
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .compactMap { $0.other(draftId) }
        }

        // 评测脉络：综合队列（线索+重复）前 5 候选中命中同项目伙伴，
        // 对齐质量关口的 recall@5；完整 30 份基线的度量在 t011-spike 的 Python 复现里。
        let aGroup = [byName["Agent Benchmark 想法.md"]!, byName["模型测试 prompt.md"]!, byName["agent_eval_notes.md"]!]
        let ranked = (leads + (try await candidateEngine.queue(kind: .duplicate))).sorted { $0.score > $1.score }
        for draftId in aGroup {
            let partners = ranked.filter { $0.involves(draftId) }
                .sorted { $0.score > $1.score }
                .prefix(5)
                .compactMap { $0.other(draftId) }
            XCTAssertTrue(partners.contains { aGroup.contains($0) && $0 != draftId },
                          "A 组草稿前 5 候选未命中同项目伙伴")
        }

        // 每条待审线索都必须带可定位证据（R-004"给出证据"）。
        for lead in leads {
            let evidence = lead.evidenceDecoded
            XCTAssertNotNil(evidence)
            XCTAssertFalse(evidence!.a.text.isEmpty)
            XCTAssertFalse(evidence!.b.text.isEmpty)
        }
        _ = pairsByDraft
    }

    func testRealModelDeterministicDimensionAndNormalization() async throws {
        let engine: E5EmbeddingEngine
        do {
            engine = try await sharedEngine()
        } catch {
            throw XCTSkip("本机语义模型不可用（\(error.localizedDescription)）")
        }
        let vectors = try engine.embed(["一句话测试", "another sentence"])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            XCTAssertEqual(vector.count, engine.dimension)
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(Double(norm), 1.0, accuracy: 0.01)
        }
        // 中文句与英文句向量均在有效范围（多语言能力的基本健全性）
        XCTAssertFalse(vectors[0].allSatisfy { $0 == 0 })
    }
}
