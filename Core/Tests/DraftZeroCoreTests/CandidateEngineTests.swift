import XCTest
import GRDB
@testable import DraftZeroCore

/// 确定性假向量器：词袋 + FNV 稳定散列分桶。共享词越多向量越接近，
/// 用于离线单测候选引擎的分流、抑制与裁决逻辑。
struct DeterministicEmbedder: TextEmbedding {
    let dimension = 512

    func embed(_ texts: [String]) throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            for token in LiteralSignals.tokens(text) {
                vector[Int(fnv(token) % UInt64(dimension))] += 1
            }
            let norm = Float(sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) }))
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
    }

    private func fnv(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

final class ChunkerTests: XCTestCase {

    func testParagraphSplitKeepsOffsetsAndHeadings() {
        let text = "# 评测方案的设计思路与分级\n\n第一段内容足够长以独立成块的内容。\n\n第二段内容也很长，避免合并。\n\n第三段。"
        let chunks = Chunker.chunk(text)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].heading, "评测方案的设计思路与分级")
        XCTAssertEqual(chunks[0].startOffset, 0)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.chunkIndex, index)
            XCTAssertNotNil(text.range(of: chunk.text)) // 片段确实来自原文（可定位证据）
        }
    }

    func testLongParagraphHardSplitAtSentence() {
        let sentence = "这是一句足够长的测试句子，用来把段落撑过硬切阈值。"
        let text = String(repeating: sentence, count: 40) // ~1000 字
        let chunks = Chunker.chunk(text)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= Chunker.maxChunkCharacters + 2 })
    }

    func testEmptyAndShortTexts() {
        XCTAssertTrue(Chunker.chunk("").isEmpty)
        XCTAssertEqual(Chunker.chunk("短文").count, 1)
    }
}

/// 可编程向量器：按完整正文映射到给定方向（未命中的给零向量），
/// 用于精确构造跨语言排序与保留规则的回归场景。
struct ScriptedEmbedder: TextEmbedding {
    let dimension = 8
    let vectors: [String: [Float]]

    func embed(_ texts: [String]) throws -> [[Float]] {
        texts.map { text in
            if let v = vectors[text] { return v }
            return [Float](repeating: 0, count: dimension)
        }
    }

    static func unit(_ index: Int, scale: Float = 1) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[index] = scale
        return v
    }

    static func normalized(_ parts: [(index: Int, scale: Float)]) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        for part in parts { v[part.index] += part.scale }
        let norm = Float(sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) }))
        return v.map { $0 / norm }
    }
}

final class CandidateEngineTests: XCTestCase {

    private var workspace: (root: URL, snapshots: URL)!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        workspace = try TestSupport.makeWorkspace()
        database = try TestSupport.makeDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
    }

    private func makeDraft(_ title: String, _ content: String) async throws -> Draft {
        try await database.createManualDraft(title: title, content: content)
    }

    func testSimilarDraftsProducePendingLead() async throws {
        let a = try await makeDraft("甲", "swiftui 界面 mac 开发 笔记 alpha beta gamma")
        let b = try await makeDraft("乙", "swiftui 界面 mac 开发 笔记 alpha beta delta")
        let unrelated = try await makeDraft("购物", "鸡蛋 牛奶 洋葱 采购")

        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        let report = try await engine.refresh(drafts: [a, b, unrelated])

        XCTAssertEqual(report.indexedDrafts, 3)
        let leads = try await engine.queue(kind: .lead)
        XCTAssertTrue(leads.contains { $0.involves(a.id) && $0.other(a.id) == b.id })
        // 无关文档之间不产生候选（R-004：无关文档不能被静默归入）
        XCTAssertFalse(leads.contains { $0.involves(unrelated.id) && ($0.other(unrelated.id) == a.id || $0.other(unrelated.id) == b.id) })
    }

    func testIdenticalContentIsClassifiedAsDuplicateNotLead() async throws {
        let a = try await makeDraft("面包笔记", "天然酵母 养种 割包 铸铁锅 蒸汽 上色")
        let b = try await makeDraft("面包笔记_备份", "天然酵母 养种 割包 铸铁锅 蒸汽 上色")
        let c = try await makeDraft("别的主题", "swiftui 界面 状态管理 mac 开发")

        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        _ = try await engine.refresh(drafts: [a, b, c])

        let dups = try await engine.queue(kind: .duplicate)
        XCTAssertTrue(dups.contains { $0.involves(a.id) && $0.other(a.id) == b.id })
        // 重复与线索不混排（R-004）
        let leads = try await engine.queue(kind: .lead)
        XCTAssertFalse(leads.contains { $0.involves(a.id) && $0.other(a.id) == b.id })
    }

    func testNoExtractableTextProducesNoCandidates() async throws {
        let a = try await makeDraft("有正文", "swiftui 界面 mac 开发 笔记 alpha")
        let scanned = Draft(title: "扫描件", content: nil, isEditable: false, hasExtractableText: false, sourceType: .pdf)
        let saved = try await database.insertDraft(scanned, initialVersion: false)

        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        _ = try await engine.refresh(drafts: [a, saved])
        let leads = try await engine.queue(kind: .lead)
        XCTAssertFalse(leads.contains { $0.involves(saved.id) })
    }

    func testRejectionSuppressesUntilContentChanges() async throws {
        let a = try await makeDraft("甲", "swiftui 界面 mac 开发 笔记 alpha beta gamma")
        let b = try await makeDraft("乙", "swiftui 界面 mac 开发 笔记 alpha beta delta")
        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        _ = try await engine.refresh(drafts: [a, b])

        let pair = try await engine.queue(kind: .lead).first!
        try await engine.decide(pairId: pair.id, status: .rejected)

        // 内容未变 → 重新生成后不再出现在待审（R-004：拒绝后不反复打扰）
        _ = try await engine.refresh(drafts: [a, b])
        let pendingAfterReject = try await engine.queue(kind: .lead)
        XCTAssertFalse(pendingAfterReject.contains { $0.id == pair.id })

        // 内容变化 → 可产生新候选；旧拒绝记录保留
        try await database.updateDraftContent(id: a.id, content: "swiftui 界面 mac 开发 笔记 alpha beta gamma epsilon")
        let aUpdated = try await database.draft(id: a.id)! // 与应用行为一致：编辑后重读
        _ = try await engine.refresh(drafts: [aUpdated, b])
        let pendingAfterChange = try await engine.queue(kind: .lead)
        XCTAssertTrue(pendingAfterChange.contains { $0.involves(a.id) && $0.other(a.id) == b.id && $0.id != pair.id })
        let rejected = try await engine.queue(kind: .lead, status: .rejected)
        XCTAssertTrue(rejected.contains { $0.id == pair.id }) // 旧记录不删除
    }

    func testDeferAndReanalyzeKeepDecisionHistory() async throws {
        let a = try await makeDraft("甲", "swiftui 界面 mac 开发 笔记 alpha beta gamma")
        let b = try await makeDraft("乙", "swiftui 界面 mac 开发 笔记 alpha beta delta")
        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        _ = try await engine.refresh(drafts: [a, b])

        let pair = try await engine.queue(kind: .lead).first!
        try await engine.decide(pairId: pair.id, status: .deferred)
        // 暂缓的候选留在"稍后处理"，不占待审数量（R-004 表格第 3 行）
        let pendingAfterDefer = try await engine.queue(kind: .lead)
        XCTAssertTrue(pendingAfterDefer.isEmpty)
        let deferred = try await engine.queue(kind: .lead, status: .deferred)
        XCTAssertEqual(deferred.count, 1)

        try await engine.reanalyze(pairId: pair.id)
        let backPending = try await engine.queue(kind: .lead)
        XCTAssertTrue(backPending.contains { $0.id == pair.id })
        XCTAssertNotNil(backPending.first?.lastDecision) // 保留裁决记录供辨认
    }

    func testAcceptAddsDraftsToProjectIdempotently() async throws {
        let a = try await makeDraft("甲", "swiftui 界面 mac 开发 笔记 alpha beta gamma")
        let b = try await makeDraft("乙", "swiftui 界面 mac 开发 笔记 alpha beta delta")
        let engine = CandidateEngine(database: database, embedder: DeterministicEmbedder())
        _ = try await engine.refresh(drafts: [a, b])
        let pair = try await engine.queue(kind: .lead).first!
        let project = try await database.createProject(name: "应用想法")

        try await engine.accept(pairId: pair.id, addDraftsToProject: project.id)
        try await engine.accept(pairId: pair.id, addDraftsToProject: project.id) // 幂等

        let members = try await database.drafts(inProject: project.id).map(\.id)
        XCTAssertEqual(Set(members), Set([a.id, b.id]))
        let pending = try await engine.queue(kind: .lead)
        XCTAssertFalse(pending.contains { $0.id == pair.id }) // 已处理不回待审
    }

    /// 回归（收尾 P1-保留规则）：旧的全局贪心双边截断下，枢纽稿被 6 个同语言
    /// 高分对占满后，它与跨语言伙伴的对被整条丢弃，伙伴稿队列里也没有该对。
    /// union 保留（每稿自己的前 K）下伙伴对必须仍在队列中。
    func testSaturatedHubKeepsCrossLanguagePartnerPair() async throws {
        let hubVector = ScriptedEmbedder.unit(0)
        let zhNoise = (1...6).map { i in
            ScriptedEmbedder.normalized([(0, 1), (i, 0.5)]) // cos(hub)=0.894
        }
        let enVector = ScriptedEmbedder.normalized([(0, 1), (7, 0.55)]) // cos(hub)=0.876

        var vectors: [String: [Float]] = ["枢纽稿正文": hubVector]
        var contents: [String] = ["枢纽稿正文"]
        for (i, v) in zhNoise.enumerated() {
            let text = "中文噪声\(i) 正文占位 词表"
            vectors[text] = v
            contents.append(text)
        }
        vectors["only english partner body text"] = enVector
        contents.append("only english partner body text")

        var drafts: [Draft] = []
        for (i, content) in contents.enumerated() {
            drafts.append(try await makeDraft(i == 0 ? "枢纽" : (i < 7 ? "噪声\(i)" : "英文伙伴"), content))
        }
        let engine = CandidateEngine(database: database, embedder: ScriptedEmbedder(vectors: vectors))
        _ = try await engine.refresh(drafts: drafts)

        let en = drafts.last!
        let queue = try await engine.queue()
        let partnerPair = queue.first { $0.involves(en.id) && $0.other(en.id) == drafts[0].id }
        XCTAssertNotNil(partnerPair, "跨语言伙伴对被保留规则整条丢弃（贪心查询不对称回归）")
    }

    /// 回归（收尾 P1-排序权重）：同语言无关对字面分 >0 会把跨语言真伙伴
    /// 挤到后面（0.3 字面权重对零重叠跨语言对的系统性压分）。
    /// 排序改为纯语义后，语义更高的真伙伴必须排在同语言噪声之前。
    func testCrossLanguagePartnerRanksAboveSameLanguageNoise() async throws {
        let zhA = ScriptedEmbedder.normalized([(0, 1), (1, 1)])
        let enB = ScriptedEmbedder.normalized([(0, 1), (1, 1), (2, 0.4)]) // cos(zhA)=0.929
        let zhN = ScriptedEmbedder.normalized([(0, 1), (1, 1), (3, 0.485)]) // cos(zhA)=0.900

        let zhAText = "评估方案 词表 数据 整理 正文"
        let zhNText = "评估方案 词表 无关 填充 正文"
        let enBText = "completely different english evaluation tokens"
        let vectors = [zhAText: zhA, zhNText: zhN, enBText: enB]

        let a = try await makeDraft("甲项目", zhAText)
        let noise = try await makeDraft("无关中文稿", zhNText)
        let en = try await makeDraft("english partner", enBText)
        let engine = CandidateEngine(database: database, embedder: ScriptedEmbedder(vectors: vectors))
        _ = try await engine.refresh(drafts: [a, noise, en])

        let queue = try await engine.queue(kind: .lead)
        let aRank = queue.firstIndex { $0.involves(a.id) && $0.other(a.id) == en.id }
        let noiseRank = queue.firstIndex { $0.involves(a.id) && $0.other(a.id) == noise.id }
        XCTAssertNotNil(aRank)
        XCTAssertNotNil(noiseRank)
        XCTAssertLessThan(aRank!, noiseRank!, "跨语言真伙伴（语义 0.93）应排在同语言噪声（语义 0.90）之前")
    }

    func testGroupFormationRequiresDirectEvidenceAndAllowsBridges() {
        func pair(_ a: UUID, _ b: UUID, score: Double) -> CandidatePair {
            CandidatePair(draftA: a, draftB: b, kind: .lead, score: score)
        }
        let a = UUID(), b = UUID(), bridge = UUID(), c = UUID(), d = UUID()
        // A-B 簇 与 C-D 簇，bridge 与两簇各有直接证据，但 A 与 C 之间无任何直接对。
        let leads = [
            pair(a, b, score: 0.9),
            pair(c, d, score: 0.85),
            pair(b, bridge, score: 0.8),
            pair(bridge, c, score: 0.7),
        ]
        let engine = CandidateEngine(database: database!, embedder: DeterministicEmbedder())
        let groups = engine.candidateGroups(from: leads)

        // 每个成员都与组内成员有直接证据（贪心聚合的约束）
        for group in groups {
            for pair in group {
                XCTAssertTrue(group.contains { $0.involves(pair.draftA) && $0.id != pair.id || $0.involves(pair.draftB) && $0.id != pair.id }
                    || group.count == 1)
            }
        }
        // 传递关系没有被捏造：不存在包含 A 与 C 直接配对（而非经由 bridge）的组
        let allPairs = groups.flatMap { $0 }
        XCTAssertTrue(allPairs.contains { $0.involves(a) && $0.involves(b) })
        XCTAssertTrue(allPairs.contains { $0.involves(bridge) && $0.involves(c) })
        XCTAssertFalse(allPairs.contains { $0.involves(a) && $0.involves(c) }) // 无直接证据的 A-C 不成对
    }
}
