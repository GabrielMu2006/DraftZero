import Foundation
import GRDB
import CryptoKit
import DraftZeroCore

/// dz-eval —— R-004 质量关口评估器（收尾方案 P0 产物）。
///
/// 与 spike（t011-spike/score.py，矩阵分数仅作诊断）不同，本评估器读取
/// **生产路径**的结果：LocalFileImporter 导入冻结的 30 份素材 →
/// CandidateEngine.refresh（生产切片/索引/打分/截断/落库）→ 直接评估
/// candidatePair 表中的待审队列。指标口径（与旧报告 17/21、40/62 同口径）：
///
/// - recall@5：每篇"有标注同项目伙伴"的草稿，其候选（按分数降序、并列按
///   对端 UUID 升序固定打破）前 5 条中至少命中一份伙伴；
/// - prec@3：每篇各取前三条候选，把确属同一项目（含标注重复对）的条数
///   除以**实际展示**的候选条数，再逐篇汇总；
/// - 候选默认取 candidatePair 全部 kind（lead + duplicate），可用
///   --kinds lead 只看项目线索（辅助指标，不替换主指标）。
///
/// 输出：逐篇 top-K 排名、每对得分/标签、错误类别、分语言组合统计与总分。

struct GroundTruthFile: Decodable {
    let threads: [String: [String]]
    let duplicates: [[String]]
    let unrelated: [String]?
}

struct PairOut: Codable {
    var rank: Int
    var other: String
    var kind: String
    var score: Double
    var semantic: Double
    var literal: Double
    var langPair: String
    var isPartner: Bool
}

struct PrecError: Codable {
    var draft: String
    var draftThread: String
    var rank: Int
    var other: String
    var kind: String
    var score: Double
    var semantic: Double
    var literal: Double
    var langPair: String
    var errorClass: String // top3 无关对挤占（irrelevant-in-top3）
}

struct DraftOut: Codable {
    var name: String
    var lang: String
    var thread: String?
    var partners: [String]
    var candidates: [PairOut]
    var recallHitAt5: Bool
    var missPartners: [String]
    var precTop3Correct: Int
    var precTop3Shown: Int
}

struct PairRow: Codable {
    var a: String
    var b: String
    var kind: String
    var score: Double
    var semantic: Double
    var literal: Double
    var label: String // partner / unrelated / duplicate
}

struct LangStat: Codable {
    var partnerInQueue: Int // 该语言组合的伙伴对出现在队列中的数量
    var partnerInTop5: Int
    var precNum: Int
    var precDen: Int
}

struct Report: Codable {
    var generatedAt: String
    var testsetDir: String
    var fileSha256: [String: String]
    var importedDocs: Int
    var importStats: ImportStats
    var queue: QueueStats
    var recall: Metric
    var precision: Metric
    var recallLeadOnly: Metric
    var precisionLeadOnly: Metric
    var languageBreakdown: [String: LangStat]
    var misses: [DraftOut]
    var precisionErrors: [PrecError]
    var drafts: [DraftOut]
    var allPairs: [PairRow]
    var runFingerprint: String

    struct ImportStats: Codable {
        var success: Int
        var duplicate: Int
        var failure: [String]
    }
    struct QueueStats: Codable {
        var chunks: Int
        var pendingLeads: Int
        var pendingDuplicates: Int
    }
    struct Metric: Codable {
        var hits: Int
        var eligible: Int
        var numerator: Int
        var denominator: Int
        var recallPercent: Double
        var precisionPercent: Double
    }
}

@main
struct DZEval {

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let testset = value("--testset"),
              let gtPath = value("--gt"),
              let dbPath = value("--db"),
              let outPath = value("--out") else {
            if args.first == "widget-qa" {
                try await widgetQA(args: args)
                return
            }
            if args.first == "debug-db" {
                try DZEval.debugDB()
                return
            }
            if args.first == "golden" {
                try await DZEval.golden(args: args)
                return
            }
            fputs("用法: dz-eval --testset DIR --gt groundtruth.json --db DB.sqlite --out report.json [--kinds lead]\n" +
                  "      dz-eval widget-qa --todo-name NAME [--recent-name NAME]\n" +
                  "      dz-eval golden --texts TEXTS.json --out GOLDEN.json\n", stderr)
            exit(2)
        }
        let kindsLeadOnly = (value("--kinds") == "lead")

        // 1. 冻结素材校验（SHA-256 摘要进报告，杜绝"重新生成同名素材仍称同集"）。
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: testset), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var fileHashes: [String: String] = [:]
        for url in fileURLs {
            fileHashes[url.lastPathComponent] =
                SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }

        // 2. 全新隔离库（删除旧文件，保证每次从零开始）。
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dbPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        let pool = try DatabasePool(path: dbPath)
        let database = try AppDatabase(pool: pool)
        let snapshots = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        // 3. 生产导入器逐份导入（文件名排序保证顺序确定；重复指纹按生产规则拒绝）。
        let importer = LocalFileImporter(database: database, snapshotsDirectory: snapshots)
        var drafts: [Draft] = []
        var duplicateCount = 0
        var failures: [String] = []
        var nameByDraft: [UUID: String] = [:]
        for url in fileURLs {
            switch await importer.importFile(at: url) {
            case .success(let draft):
                drafts.append(draft)
                nameByDraft[draft.id] = url.lastPathComponent
            case .duplicate:
                duplicateCount += 1
            case .failure(let reason):
                failures.append("\(url.lastPathComponent): \(reason)")
            }
        }

        // 4. 生产引擎：切片 → 索引 → 候选落库。
        let engine = CandidateEngine(database: database, embedder: try await E5EmbeddingEngine())
        let engineReport = try await engine.refresh(drafts: drafts)

        // 5. 读取生产候选队列并评估。
        let gt = try JSONDecoder().decode(
            GroundTruthFile.self, from: Data(contentsOf: URL(fileURLWithPath: gtPath)))
        let report = try await evaluate(
            database: database, drafts: drafts, nameByDraft: nameByDraft, gt: gt,
            testset: testset, fileHashes: fileHashes, engineReport: engineReport,
            duplicatesRejected: duplicateCount, failures: failures)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: outPath))

        print("imported=\(report.importedDocs) duplicate=\(duplicateCount) failures=\(failures.count)")
        print("queue chunks=\(report.queue.chunks) leads=\(report.queue.pendingLeads) dups=\(report.queue.pendingDuplicates)")
        print(String(format: "recall@5      = %.1f%% (%d/%d)", report.recall.recallPercent, report.recall.hits, report.recall.eligible))
        print(String(format: "prec@3        = %.1f%% (%d/%d)", report.precision.precisionPercent, report.precision.numerator, report.precision.denominator))
        print(String(format: "recall@5 lead = %.1f%% (%d/%d)", report.recallLeadOnly.recallPercent, report.recallLeadOnly.hits, report.recallLeadOnly.eligible))
        print(String(format: "prec@3  lead  = %.1f%% (%d/%d)", report.precisionLeadOnly.precisionPercent, report.precisionLeadOnly.numerator, report.precisionLeadOnly.denominator))
        print("run fingerprint = \(report.runFingerprint)")
        print("report → \(outPath)")
        if kindsLeadOnly { print("（--kinds lead 只改变展示口径，主指标始终同时输出两种）") }
    }

    // MARK: - 评估

    static func evaluate(
        database: AppDatabase, drafts: [Draft], nameByDraft: [UUID: String],
        gt: GroundTruthFile, testset: String, fileHashes: [String: String],
        engineReport: CandidateReport, duplicatesRejected: Int, failures: [String]
    ) async throws -> Report {

        var threadOf: [String: String] = [:]
        for (g, members) in gt.threads {
            for m in members { threadOf[m] = g }
        }
        var partners: [String: Set<String>] = [:]
        for (name, g) in threadOf {
            partners[name] = Set(gt.threads[g]!).subtracting([name])
        }
        for pair in gt.duplicates {
            partners[pair[0], default: []].insert(pair[1])
            partners[pair[1], default: []].insert(pair[0])
        }

        // 语言按正文判断（含 CJK 即计 zh），不以文件名代替。
        func lang(_ text: String?) -> String {
            guard let text else { return "en" }
            return text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? "zh" : "en"
        }
        let langOf: [UUID: String] = drafts.reduce(into: [:]) { $0[$1.id] = lang($1.content) }

        let allPairs = try await database.pool.read { db in
            try CandidatePair.filter(Column("status") == CandidateStatus.pending.rawValue).fetchAll(db)
        }
        let chunks = try await database.pool.read { db in try IndexChunk.fetchCount(db) }

        var byDraft: [UUID: [CandidatePair]] = [:]
        for pair in allPairs {
            byDraft[pair.draftA, default: []].append(pair)
            if pair.draftB != pair.draftA { byDraft[pair.draftB, default: []].append(pair) }
        }
        for key in byDraft.keys {
            byDraft[key]!.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return otherOf($0, key).uuidString < otherOf($1, key).uuidString
            }
        }

        func scores(_ pair: CandidatePair) -> (Double, Double) {
            guard let ev = pair.evidenceDecoded else { return (0, 0) }
            return (ev.semanticScore, ev.literalScore)
        }

        var draftsOut: [DraftOut] = []
        var recallHits = 0, eligibleCount = 0
        var precNum = 0, precDen = 0
        var recallLeadHits = 0, precLeadNum = 0, precLeadDen = 0
        var langStats: [String: LangStat] = [:]
        var misses: [DraftOut] = []
        var precErrors: [PrecError] = []

        func bump(_ combo: String, _ key: WritableKeyPath<LangStat, Int>) {
            var stat = langStats[combo] ?? LangStat(partnerInQueue: 0, partnerInTop5: 0, precNum: 0, precDen: 0)
            stat[keyPath: key] += 1
            langStats[combo] = stat
        }

        for draft in drafts {
            let name = nameByDraft[draft.id] ?? draft.title
            guard let thread = threadOf[name] else { continue }
            eligibleCount += 1
            let plist = partners[name] ?? []
            var candidates: [PairOut] = []
            var leadCandidates: [PairOut] = []
            for (rank, pair) in (byDraft[draft.id] ?? []).enumerated() {
                let other = otherOf(pair, draft.id)
                let otherName = nameByDraft[other] ?? "?"
                let (sem, lit) = scores(pair)
                let entry = PairOut(
                    rank: rank + 1, other: otherName, kind: pair.kind.rawValue,
                    score: pair.score, semantic: sem, literal: lit,
                    langPair: "\(langOf[draft.id] ?? "?")-\(langOf[other] ?? "?")",
                    isPartner: plist.contains(otherName))
                candidates.append(entry)
                if pair.kind == .lead { leadCandidates.append(entry) }
            }

            let hit = candidates.prefix(5).contains { $0.isPartner }
            if hit { recallHits += 1 }
            let top3 = candidates.prefix(3)
            let correct3 = top3.filter { $0.isPartner }.count
            precNum += correct3
            precDen += top3.count
            let leadTop3 = leadCandidates.prefix(3)
            precLeadNum += leadTop3.filter { $0.isPartner }.count
            precLeadDen += leadTop3.count
            if leadCandidates.prefix(5).contains(where: { $0.isPartner }) { recallLeadHits += 1 }

            // 语言组合统计：伙伴级 recall + top3 精度。
            for partnerName in plist.sorted() {
                let combo = "\(langOf[draft.id] ?? "?")↔\(langByName(partnerName, nameByDraft, drafts, langOf))"
                let rank = candidates.first { $0.other == partnerName }?.rank
                bump(combo, \.partnerInQueue)
                if let rank, rank <= 5 { bump(combo, \.partnerInTop5) }
            }
            for entry in top3 {
                bump(entry.langPair, \.precDen)
                if entry.isPartner { bump(entry.langPair, \.precNum) }
            }

            let out = DraftOut(
                name: name, lang: langOf[draft.id] ?? "?", thread: thread,
                partners: plist.sorted(), candidates: candidates,
                recallHitAt5: hit, missPartners: hit ? [] : plist.sorted(),
                precTop3Correct: correct3, precTop3Shown: top3.count)
            draftsOut.append(out)
            if !hit { misses.append(out) }
            for entry in top3 where !entry.isPartner {
                precErrors.append(PrecError(
                    draft: name, draftThread: thread, rank: entry.rank, other: entry.other,
                    kind: entry.kind, score: entry.score, semantic: entry.semantic,
                    literal: entry.literal, langPair: entry.langPair,
                    errorClass: "irrelevant-in-top3"))
            }
        }

        func recallMetric(hits: Int) -> Report.Metric {
            Report.Metric(hits: hits, eligible: eligibleCount, numerator: 0, denominator: 0,
                          recallPercent: eligibleCount == 0 ? 0 : Double(hits) / Double(eligibleCount) * 100,
                          precisionPercent: 0)
        }
        func precMetric(num: Int, den: Int) -> Report.Metric {
            Report.Metric(hits: 0, eligible: 0, numerator: num, denominator: den,
                          recallPercent: 0,
                          precisionPercent: den == 0 ? 0 : Double(num) / Double(den) * 100)
        }

        // 全部待审对的得分/标签清单（"每对得分/标签"产物）。
        var pairRows: [PairRow] = []
        for pair in allPairs {
            let aName = nameByDraft[pair.draftA] ?? "?"
            let bName = nameByDraft[pair.draftB] ?? "?"
            let (sem, lit) = scores(pair)
            let label = pair.kind == .duplicate ? "duplicate"
                : ((partners[aName] ?? []).contains(bName) ? "partner" : "unrelated")
            pairRows.append(PairRow(a: aName, b: bName, kind: pair.kind.rawValue,
                                    score: pair.score, semantic: sem, literal: lit, label: label))
        }
        pairRows.sort { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }

        // 指纹取 3 位小数：CoreML 推理跨运行有 ~1e-5 的线程归约浮点抖动，
        // 全精度分数无法逐位复现；3 位小数以下排序差异不影响门槛指标
        // （三次运行 21/21 与 47/63 完全一致，见 P0/P1 报告）。
        var fingerprint = "\(allPairs.count)|"
        for pair in allPairs.sorted(by: { pairID($0) < pairID($1) }) {
            fingerprint += "\(pairID(pair)):\(String(format: "%.3f", pair.score))|\(pair.kind.rawValue);"
        }

        return Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            testsetDir: testset,
            fileSha256: fileHashes,
            importedDocs: drafts.count,
            importStats: .init(success: drafts.count, duplicate: duplicatesRejected, failure: failures),
            queue: .init(chunks: chunks, pendingLeads: engineReport.pendingLeads, pendingDuplicates: engineReport.pendingDuplicates),
            recall: recallMetric(hits: recallHits),
            precision: precMetric(num: precNum, den: precDen),
            recallLeadOnly: recallMetric(hits: recallLeadHits),
            precisionLeadOnly: precMetric(num: precLeadNum, den: precLeadDen),
            languageBreakdown: langStats,
            misses: misses,
            precisionErrors: precErrors.sorted { ($0.draft, $0.rank) < ($1.draft, $1.rank) },
            drafts: draftsOut.sorted { $0.name < $1.name },
            allPairs: pairRows,
            runFingerprint: fingerprint)
    }

    static func langByName(_ name: String, _ nameByDraft: [UUID: String],
                           _ drafts: [Draft], _ langOf: [UUID: String]) -> String {
        for draft in drafts where nameByDraft[draft.id] == name {
            return langOf[draft.id] ?? "?"
        }
        return "?"
    }

    static func otherOf(_ pair: CandidatePair, _ id: UUID) -> UUID {
        pair.draftA == id ? pair.draftB : pair.draftA
    }

    // MARK: - golden（V0.2.0 M0）：生产 E5 引擎的 token IDs 与 384 维黄金向量，
    // 供 Windows C# 端做逐条对齐（token 完全一致）与余弦（≥0.995）校验。
    // 输入 JSON：[{"id": "...", "text": "..."}]；
    // 输出 JSON：[{"id": "...", "text": "...", "tokenIds": [Int], "vector": [Float]}]。

    struct GoldenInput: Decodable {
        let id: String
        let text: String
    }

    struct GoldenItem: Codable {
        let id: String
        let text: String
        let tokenIds: [Int]
        let vector: [Float]
    }

    static func golden(args: [String]) async throws {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let textsPath = value("--texts"), let outPath = value("--out") else {
            fputs("dz-eval golden --texts TEXTS.json --out GOLDEN.json\n", stderr)
            exit(2)
        }
        let inputs = try JSONDecoder().decode([GoldenInput].self, from: Data(contentsOf: URL(fileURLWithPath: textsPath)))
        let engine = try await E5EmbeddingEngine()
        let vectors = try engine.embed(inputs.map(\.text))
        var items: [GoldenItem] = []
        for (input, vector) in zip(inputs, vectors) {
            var ids = try engine.tokenIDs(text: E5EmbeddingEngine.queryPrefix + input.text)
            if ids.count > E5EmbeddingEngine.maxTokens {
                ids = Array(ids[0..<E5EmbeddingEngine.maxTokens])
            }
            items.append(GoldenItem(
                id: input.id, text: input.text, tokenIds: ids,
                vector: vector.map { Float($0) }))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(items).write(to: URL(fileURLWithPath: outPath))
        print("golden → \(outPath)（\(items.count) 条）")
    }

    //
    // 与 Widget/DraftZeroWidget.swift 完全同源：defaultDatabaseURL() 定位、
    // 时间线两条 SQL 读取、AppIntent 调用的 setProjectStatus 写入。
    // 运行前提：launchctl setenv DZ_WORKSPACE_DIR <隔离目录>（组件进程同样继承）。
    static func widgetQA(args: [String]) async throws {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let url = AppDatabase.defaultDatabaseURL()
        print("resolved database url = \(url.path)")
        let pool = try DatabasePool(path: url.path)

        let todoSQL = "SELECT id, name FROM project WHERE status = ? ORDER BY createdAt DESC LIMIT 2"
        let recentSQL = "SELECT id, name FROM project WHERE status != ? ORDER BY createdAt DESC LIMIT 4"

        func readWidgetEntry() throws -> (todo: [(UUID, String)], recent: [(UUID, String)]) {
            // 逐字镜像 Widget/DraftZeroWidget.readProjectsEntry：SQL 只取 id+name，
            // 解码用 `as UUID?`；状态以隔离库直查为对照展示。
            var todo: [(UUID, String)] = []
            var recent: [(UUID, String)] = []
            try pool.read { db in
                let todoRows = try Row.fetchAll(db, sql: todoSQL, arguments: ["todo"])
                let todoIds = todoRows.compactMap { $0["id"] as UUID? }
                if todoRows.count != todoIds.count {
                    print("⚠️ Widget 解码缺陷：\(todoRows.count) 行中只有 \(todoIds.count) 行能 `as UUID?` 解码")
                }
                todo = zip(todoIds, todoRows.compactMap { $0["name"] as String? }).map { ($0, $1) }
                let recentRows = try Row.fetchAll(db, sql: recentSQL, arguments: ["archived"])
                var recentPairs: [(UUID, String)] = []
                for row in recentRows {
                    guard let id = row["id"] as UUID?, let name = row["name"] as String?,
                          !todoIds.contains(id) else { continue }
                    recentPairs.append((id, name))
                }
                recent = recentPairs
            }
            return (todo, recent)
        }

        let (todo, recent) = try readWidgetEntry()
        print("timeline read → todo: \(todo.map { "\($0.1)" }) | recent: \(recent.map { "\($0.1)" })")
        let db = try AppDatabase(pool: pool)
        if let todoItem = todo.first {
            // 与 MarkProjectDoneIntent.perform 相同的调用。
            try await db.setProjectStatus(id: todoItem.0, status: .mostlyDone)
            print("intent [标记为基本完成] applied to '\(todoItem.1)'")
        }
        if let recentItem = recent.first {
            // 与 MarkProjectTodoIntent.perform 相同的调用。
            try await db.setProjectStatus(id: recentItem.0, status: .todo)
            print("intent [设为 TODO] applied to '\(recentItem.1)'")
        }
        let after = try readWidgetEntry()
        print("timeline after → todo: \(after.todo.map { "\($0.1)" }) | recent: \(after.recent.map { "\($0.1)" })")
    }

    static func pairID(_ pair: CandidatePair) -> String {
        let a = pair.draftA.uuidString, b = pair.draftB.uuidString
        return a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }
}

extension DZEval {
    static func debugDB() throws {
        let pool = try DatabasePool(path: AppDatabase.defaultDatabaseURL().path)
        try pool.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT count(*) FROM project") ?? -1
            let jm = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?"
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            print("count=\(n) journal=\(jm) tables=\(tables.joined(separator: ","))")
        }
    }
}
