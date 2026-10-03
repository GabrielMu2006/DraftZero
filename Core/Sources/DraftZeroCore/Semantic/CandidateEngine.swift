import Foundation
import GRDB

// MARK: - 模型

/// 候选类型（R-004）：重复与线索分开，不混排。
public enum CandidateKind: String, Codable, Sendable, DatabaseValueConvertible {
    case lead       // 项目线索
    case duplicate  // 可能重复
}

public enum CandidateStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case accepted
    case rejected
    case deferred
}

/// 可定位的证据（R-004"给出证据"）：两份文档中可跳回原位的片段与共同术语。
public struct PairEvidence: Codable, Sendable, Equatable {
    public struct Snippet: Codable, Sendable, Equatable {
        public let draftId: UUID
        public let chunkIndex: Int
        public let startOffset: Int
        public let heading: String?
        public let text: String
    }

    public let a: Snippet
    public let b: Snippet
    /// 共同术语；为空表示纯语义相近，界面显示"内容含义相近"（不虚构共同关键词）。
    public let commonTerms: [String]
    public let semanticScore: Double
    public let literalScore: Double
}

/// 候选对。接受/拒绝/暂缓由用户决定；候选不是项目归属（SPEC §5）。
public struct CandidatePair: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var draftA: UUID
    public var draftB: UUID
    public var kind: CandidateKind
    public var score: Double
    public var evidence: String?
    public var status: CandidateStatus
    public var fingerprintA: String?
    public var fingerprintB: String?
    /// 重新分析后保留此前裁决记录供辨认（R-004 表格第 4 行）。
    public var lastDecision: String?
    public var createdAt: Date
    public var decidedAt: Date?

    public static let databaseTableName = "candidatePair"

    public init(
        id: UUID = UUID(), draftA: UUID, draftB: UUID, kind: CandidateKind, score: Double,
        evidence: String? = nil, status: CandidateStatus = .pending,
        fingerprintA: String? = nil, fingerprintB: String? = nil,
        lastDecision: String? = nil, createdAt: Date = Date(), decidedAt: Date? = nil
    ) {
        self.id = id
        self.draftA = draftA
        self.draftB = draftB
        self.kind = kind
        self.score = score
        self.evidence = evidence
        self.status = status
        self.fingerprintA = fingerprintA
        self.fingerprintB = fingerprintB
        self.lastDecision = lastDecision
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }

    public var evidenceDecoded: PairEvidence? {
        guard let evidence, let data = evidence.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairEvidence.self, from: data)
    }

    public func involves(_ draftId: UUID) -> Bool {
        draftA == draftId || draftB == draftId
    }

    public func other(_ draftId: UUID) -> UUID? {
        if draftA == draftId { return draftB }
        if draftB == draftId { return draftA }
        return nil
    }
}

// MARK: - 阈值（A-007：门槛 recall@5 ≥80% 且 prec@3 ≥70%；取值依据见下与 release-closure 消融报告）

public enum CandidateTuning {
    /// 语义近重复阈值（spike：重复文件对 1.000，无关对均值 ~0.80）。
    public static let duplicateSemantic: Double = 0.98
    /// 项目线索地板（V0.2.0 F-008 重校准：e5-small 绝对余弦挤在 0.82–0.94 窄带，
    /// 0.45 地板全数放行导致真实使用中噪声线索刷屏；冻结集复测见 Windows/evidence/M0-TECHNICAL-GATE.md 附录）。
    public static let leadSemanticFloor: Double = 0.90
    /// 合成分地板：排序已不含字面分量（literalWeight = 0），与语义地板一致。
    public static let leadCombined: Double = 0.90
    /// 排序权重（2026-09-29 收尾 P1，冻结 30 份集消融）：
    /// 字面分进入合成分会系统性抬升同语言噪声对（任何中中/英英对都共享高频
    /// 字词，字面分 ~0.02–0.10），而跨语言真伙伴字面恒为 0，被稳定压到
    /// 噪声对之后——基线 prec@3 40/63（63.5%），纯语义排序 46/63（73.0%），
    /// recall 亦从 17/21 修复到 21/21。字面信号不删除：仍用于证据展示
    /// （共同术语/标题命中）与重复检测（指纹/0.98 阈值），见 A-005。
    public static let semanticWeight: Double = 1.0
    public static let literalWeight: Double = 0.0
    /// 每份草稿保留的候选数（质量关口按"前 5"评估，多留一个余量）。
    public static let topKPerDraft = 6
    /// 产生"项目线索"（语义）候选的最低正文字符数（与 Windows 端一致，见 CandidateTuning）。
    public static let minLeadCharacters = 30
}

// MARK: - 字面信号（第一层：中英文词、汉字短片段、标题）

public enum LiteralSignals {

    /// 拉丁词（小写，≥2 字符）+ 汉字二元组。
    /// 性能注记：NSRegularExpression 编译约 50ms/次（ICU），2026-10 基线实测
    /// 逐调用编译在千稿级工作区占分钟级；实例线程安全（Apple 文档），故静态缓存。
    nonisolated(unsafe) private static let wordRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "[a-z0-9]{2,}")

    public static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        var result = Set<String>()
        if let wordRegex {
            let range = NSRange(lowered.startIndex..., in: lowered)
            for match in wordRegex.matches(in: lowered, range: range) {
                if let r = Range(match.range, in: lowered) {
                    result.insert(String(lowered[r]))
                }
            }
        }
        let scalars = Array(lowered.unicodeScalars)
        guard scalars.count >= 2 else { return result }
        for i in 0..<(scalars.count - 1) where isCJK(scalars[i]) && isCJK(scalars[i + 1]) {
            result.insert(String(String.UnicodeScalarView([scalars[i], scalars[i + 1]])))
        }
        return result
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// 共同术语按"更长更罕见"优先，用于证据展示。
    public static func commonTerms(_ a: Set<String>, _ b: Set<String>, limit: Int = 6) -> [String] {
        let shared = a.intersection(b).sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
        return Array(shared.prefix(limit))
    }
}

// MARK: - 候选引擎

public struct CandidateReport: Sendable, Equatable {
    public let indexedDrafts: Int
    public let pendingLeads: Int
    public let pendingDuplicates: Int
}

public struct CandidateEngine: Sendable {

    public let database: AppDatabase
    public let embedder: TextEmbedding

    public init(database: AppDatabase, embedder: TextEmbedding) {
        self.database = database
        self.embedder = embedder
    }

    /// 增量索引 + 重新生成候选（新增/编辑/删除只影响相关内容；SPEC §3"切片与索引"）。
    public func refresh(drafts: [Draft]) async throws -> CandidateReport {
        try await database.refreshSemanticIndex(drafts: drafts, embedder: embedder)
        try await regenerate(drafts: drafts)
        return try await counts()
    }

    // MARK: 候选生成

    public func regenerate(drafts: [Draft]) async throws {
        let chunksByDraft = try await database.chunksByDraft()
        let draftsById = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        let fingerprints = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, TextReading.fingerprint(of: $0.content ?? ""))
        })
        let bodyTokens = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, LiteralSignals.tokens($0.content ?? ""))
        })
        let titleTokens = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, LiteralSignals.tokens($0.title))
        })

        let withVectors = drafts.filter { chunksByDraft[$0.id]?.isEmpty == false }
        var candidates: [String: ScoredPair] = [:]
        for i in 0..<withVectors.count {
            for j in (i + 1)..<withVectors.count {
                let draftA = withVectors[i], draftB = withVectors[j]
                let chunksA = chunksByDraft[draftA.id] ?? []
                let chunksB = chunksByDraft[draftB.id] ?? []

                // 文档分 = 切片对最大余弦，并保留最佳切片对作证据（"相近段落"）。
                var best = -Double.infinity
                var bestA: IndexChunk?
                var bestB: IndexChunk?
                for chunkA in chunksA {
                    for chunkB in chunksB {
                        let s = Double(Self.cosine(chunkA.vector, chunkB.vector))
                        if s > best {
                            best = s
                            bestA = chunkA
                            bestB = chunkB
                        }
                    }
                }
                guard best > 0, let chunkA = bestA, let chunkB = bestB else { continue }

                let literal = Self.literalScore(
                    bodyTokens[draftA.id] ?? [], bodyTokens[draftB.id] ?? [],
                    titleTokens[draftA.id] ?? [], titleTokens[draftB.id] ?? [])
                let combined = CandidateTuning.semanticWeight * best
                    + CandidateTuning.literalWeight * literal
                let isDuplicate = best >= CandidateTuning.duplicateSemantic
                    || fingerprints[draftA.id] == fingerprints[draftB.id]
                // F-008：线索候选要求双方正文达到最低长度（短文语义不可靠）；
                // "可能重复"（指纹判定）不受限。
                let bothLeadEligible =
                    (draftA.content?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0)
                        >= CandidateTuning.minLeadCharacters
                    && (draftB.content?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0)
                        >= CandidateTuning.minLeadCharacters
                guard isDuplicate
                        || (bothLeadEligible && best >= CandidateTuning.leadSemanticFloor && combined >= CandidateTuning.leadCombined) else {
                    continue
                }

                let evidence = PairEvidence(
                    a: .init(draftId: draftA.id, chunkIndex: chunkA.chunkIndex,
                             startOffset: chunkA.startOffset, heading: chunkA.heading, text: chunkA.text),
                    b: .init(draftId: draftB.id, chunkIndex: chunkB.chunkIndex,
                             startOffset: chunkB.startOffset, heading: chunkB.heading, text: chunkB.text),
                    commonTerms: LiteralSignals.commonTerms(
                        bodyTokens[draftA.id] ?? [], bodyTokens[draftB.id] ?? []),
                    semanticScore: best,
                    literalScore: literal)

                let pair = ScoredPair(
                    a: draftA.id, b: draftB.id,
                    semantic: best, combined: combined, literal: literal,
                    isDuplicate: isDuplicate, evidence: evidence)
                let key = Self.pairKey(draftA.id, draftB.id)
                if let existing = candidates[key], existing.combined >= pair.combined {
                    continue
                }
                candidates[key] = pair
            }
        }

        // 每份草稿保留**自己的**前 K 个候选（并集）。旧实现是全局贪心双边截断：
        // 一个端点满槽后，涉及它的中分段对被整条丢弃，另一端点也失去该候选——
        // zh 稿被 zh-zh 高分对占满槽位时，其跨语言伙伴对双端都不入库，
        // 造成查询不对称（基线 4 个 recall miss 的主因，消融见 release-closure 报告）。
        var perDraft: [UUID: [ScoredPair]] = [:]
        for pair in candidates.values.sorted(by: Self.rankOrder) {
            perDraft[pair.a, default: []].append(pair)
            if pair.b != pair.a { perDraft[pair.b, default: []].append(pair) }
        }
        var kept: [String: ScoredPair] = [:]
        for list in perDraft.values {
            for pair in list.prefix(CandidateTuning.topKPerDraft) {
                kept[Self.pairKey(pair.a, pair.b)] = pair
            }
        }
        let finalPairs = kept.values

        // 落库（R-004 表格）：pending 更新；rejected/deferred 内容未变则抑制；
        // 内容已变可产生新候选，旧记录保留；无正文文档不产生候选。
        let evidenceEncoder = JSONEncoder()
        try await database.pool.write { db in
            // 一次取全表现有行，按无序对键聚合（同对取 createdAt 最新者）。
            // 2026-10 性能基线（Windows/evidence/ENGINE-PERF-BASELINE-2026-10-03.md）：
            // 逐对 SELECT 的 GRDB 异步往返常数 ~19-35ms/条，百稿级即分钟级——批量读是
            // O(表大小) 一次往返，语义不变。
            var existingByPair: [String: CandidatePair] = [:]
            for row in try CandidatePair.fetchAll(db) {
                let key = Self.pairKey(row.draftA, row.draftB)
                if let prev = existingByPair[key], prev.createdAt >= row.createdAt { continue }
                existingByPair[key] = row
            }
            for pair in finalPairs {
                let existing = existingByPair[Self.pairKey(pair.a, pair.b)]
                let kind: CandidateKind = pair.isDuplicate ? .duplicate : .lead
                let evidenceData = try evidenceEncoder.encode(pair.evidence)
                let evidenceJSON = String(data: evidenceData, encoding: .utf8)

                guard let existing else {
                    var row = CandidatePair(
                        draftA: pair.a, draftB: pair.b, kind: kind,
                        score: pair.combined, evidence: evidenceJSON, status: .pending)
                    row.fingerprintA = fingerprints[pair.a]
                    row.fingerprintB = fingerprints[pair.b]
                    try row.insert(db)
                    continue
                }

                if existing.status == .pending {
                    var updated = existing
                    updated.score = pair.combined
                    updated.kind = kind
                    updated.evidence = evidenceJSON
                    try updated.update(db)
                    continue
                }

                let unchanged = existing.fingerprintA == fingerprints[pair.a]
                    && existing.fingerprintB == fingerprints[pair.b]
                if !unchanged {
                    var row = CandidatePair(
                        draftA: pair.a, draftB: pair.b, kind: kind,
                        score: pair.combined, evidence: evidenceJSON, status: .pending,
                        lastDecision: existing.lastDecision
                            ?? "\(existing.status.rawValue)（内容已变化）")
                    row.fingerprintA = fingerprints[pair.a]
                    row.fingerprintB = fingerprints[pair.b]
                    try row.insert(db)
                }
            }

            // F-008 收回（与 Windows 端一致）：pending 行是纯机器建议。地板重校准、
            // 阈值调整或内容删除后不再达标的旧 pending 行若不回收，会永久占据待审
            // 队列。已拒绝/暂缓行有裁决记录，保留（R-004 抑制规则依赖）。
            let keptKeys = Set(finalPairs.map { Self.pairKey($0.a, $0.b) })
            let pendingRows = try Row.fetchAll(db, sql: "SELECT id, draftA, draftB FROM candidatePair WHERE status = ?",
                                               arguments: [CandidateStatus.pending.rawValue])
            for row in pendingRows {
                let id: UUID = row["id"]
                let a: UUID = row["draftA"]
                let b: UUID = row["draftB"]
                let key = Self.pairKey(a, b)
                if !keptKeys.contains(key) {
                    _ = try CandidatePair.deleteOne(db, key: id)
                }
            }
        }
        _ = draftsById
    }

    struct ScoredPair {
        let a: UUID, b: UUID
        let semantic: Double
        let combined: Double
        let literal: Double
        let isDuplicate: Bool
        let evidence: PairEvidence
    }

    static func pairKey(_ a: UUID, _ b: UUID) -> String {
        a.uuidString < b.uuidString ? "\(a.uuidString)|\(b.uuidString)" : "\(b.uuidString)|\(a.uuidString)"
    }

    /// 固定排序：combined 降序，并列依次按 semantic、literal、pairKey；
    /// 队列展示与质量评估依赖同一规则保证可重复。
    static func rankOrder(_ lhs: ScoredPair, _ rhs: ScoredPair) -> Bool {
        if lhs.combined != rhs.combined { return lhs.combined > rhs.combined }
        if lhs.semantic != rhs.semantic { return lhs.semantic > rhs.semantic }
        if lhs.literal != rhs.literal { return lhs.literal > rhs.literal }
        return pairKey(lhs.a, lhs.b) < pairKey(rhs.a, rhs.b)
    }

    static func literalScore(_ bodyA: Set<String>, _ bodyB: Set<String>,
                             _ titleA: Set<String>, _ titleB: Set<String>) -> Double {
        0.7 * LiteralSignals.jaccard(bodyA, bodyB) + 0.3 * LiteralSignals.jaccard(titleA, titleB)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        return dot / max(sqrt(na) * sqrt(nb), 1e-12)
    }

    // MARK: - 队列与裁决

    public func counts() async throws -> CandidateReport {
        try await database.pool.read { db in
            let indexed = try IndexStatus.fetchCount(db)
            let pending = try CandidatePair.filter(Column("status") == CandidateStatus.pending.rawValue)
            let leads = try pending.filter(Column("kind") == CandidateKind.lead.rawValue).fetchCount(db)
            let dups = try pending.filter(Column("kind") == CandidateKind.duplicate.rawValue).fetchCount(db)
            return CandidateReport(indexedDrafts: indexed, pendingLeads: leads, pendingDuplicates: dups)
        }
    }

    public func queue(kind: CandidateKind? = nil, status: CandidateStatus = .pending) async throws -> [CandidatePair] {
        try await database.pool.read { db in
            var request = CandidatePair.filter(Column("status") == status.rawValue)
            if let kind {
                request = request.filter(Column("kind") == kind.rawValue)
            }
            return try request
                .order(Column("score").desc, Column("draftA").asc, Column("draftB").asc)
                .fetchAll(db)
        }
    }

    /// 候选组预览（R-004"形成候选组"）：从待审线索对贪心聚合；
    /// 每个成员都必须与组内某成员有直接证据；桥接文档可出现在多个组；
    /// 不做 A~B~C ⇒ A~C 的传递推断。
    public func candidateGroups(from pendingLeads: [CandidatePair]) -> [[CandidatePair]] {
        var groups: [[CandidatePair]] = []
        for pair in pendingLeads.sorted(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let indexA = groups.firstIndex { members in members.contains { $0.involves(pair.draftA) } }
            let indexB = groups.firstIndex { members in members.contains { $0.involves(pair.draftB) } }
            switch (indexA, indexB) {
            case (nil, nil):
                groups.append([pair])
            case (let i?, nil):
                groups[i].append(pair)
            case (nil, let j?):
                groups[j].append(pair)
            case (let i?, let j?):
                if i == j {
                    groups[i].append(pair)
                } else {
                    // 合并会造成无直接证据的成员 → 两组保持独立（桥接文档两边都出现）
                    groups[i].append(pair)
                }
            }
        }
        return groups
    }

    /// 接受：把勾选的草稿加入项目（真实归属由 projectDraft 承担，幂等），候选标记已处理。
    public func accept(pairId: UUID, addDraftsToProject projectId: UUID) async throws {
        try await database.pool.write { db in
            guard var pair = try CandidatePair.fetchOne(db, key: pairId) else { return }
            for draftId in [pair.draftA, pair.draftB] {
                guard try Draft.exists(db, key: draftId), try Project.exists(db, key: projectId) else { continue }
                if try ProjectDraft
                    .filter(Column("projectId") == projectId && Column("draftId") == draftId)
                    .fetchOne(db) == nil {
                    try ProjectDraft(projectId: projectId, draftId: draftId).insert(db)
                }
            }
            pair.status = .accepted
            pair.decidedAt = Date()
            try pair.update(db)
        }
    }

    public func decide(pairId: UUID, status: CandidateStatus) async throws {
        try await database.pool.write { db in
            guard var pair = try CandidatePair.fetchOne(db, key: pairId) else { return }
            pair.status = status
            pair.decidedAt = Date()
            try pair.update(db)
        }
    }

    /// 用户主动重新分析：回到待审，保留此前裁决记录（R-004 表格第 4 行）。
    public func reanalyze(pairId: UUID) async throws {
        try await database.pool.write { db in
            guard var pair = try CandidatePair.fetchOne(db, key: pairId) else { return }
            if pair.status != .pending {
                let when = pair.decidedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                pair.lastDecision = "\(pair.status.rawValue) \(when)"
            }
            pair.status = .pending
            pair.decidedAt = nil
            try pair.update(db)
        }
    }
}
