import Foundation
import GRDB
import CoreML
import Tokenizers
import Hub
import DraftZeroCore

// dz-bench —— 引擎性能基准（2026-10-03）。只调用生产 API，不修改任何引擎行为。
//
// 子命令：
//   embed                        推理微基准：生产 CoreML 引擎对不同长度/语言文本的延迟分布
//   scale --corpus DIR --sizes N,N --db DIR --out JSON
//                                规模曲线：切片+索引（推理+落库）与候选生成（O(n²) 评分）分相计时
//
// 语料由 /tmp/dzbench/gen_corpus.py 从冻结 30 份集合成；基准直接构造 Draft，
// 不经导入器（把"收纳"与"引擎"分离，导入性能不在本基准范围）。

struct Stats: Codable {
    var n: Int
    var meanMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var minMs: Double
    var maxMs: Double
}

/// Duration → 毫秒（seconds×1000 + attoseconds/1e15）。
/// 2026-10-04 勘误：此前用 attoseconds/1e12 得到的是微秒却被当作毫秒报告，
/// 导致基线文档全体数值放大 ~1000x（详见证据文档勘误节）。
func durationMs(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
}

func stats(_ samples: [Double]) -> Stats {
    let sorted = samples.sorted()
    let n = sorted.count
    let total = samples.reduce(0.0, +)
    let mean = total / Double(n)
    func pct(_ p: Double) -> Double {
        let idx = min(n - 1, Int(p / 100.0 * Double(n)))
        return sorted[idx]
    }
    let p50 = pct(50)
    let p95 = pct(95)
    let lo = sorted.first ?? 0
    let hi = sorted.last ?? 0
    return Stats(n: n, meanMs: mean, p50Ms: p50, p95Ms: p95, minMs: lo, maxMs: hi)
}

func value(_ flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - embed 微基准

func runEmbed() async throws {
    let engine = try await E5EmbeddingEngine()
    // 与合成语料同量级的文本桶（中文按 ~1 token/字，600 字贴 512 token 上限）
    let buckets: [(name: String, make: (Int) -> String)] = [
        ("zh-short-50",  { i in "深夜灵感第\(i)条：雨夜书店的桥段还可以再压一压，明天改。" }),
        ("zh-medium-200", { i in String(repeating: "本地优先的草稿收纳应用要把语义线索控制在可审的量级，", count: 3) + "编号\(i)。" }),
        ("zh-long-600",   { i in String(repeating: "这是一段足够长的中文段落，用来测试接近切片上限时分词与推理的开销。", count: 16) + "编号\(i)。" }),
        ("en-short-40",   { i in "Bench note \(i): short English draft about benchmarking ideas." }),
        ("en-long-600",   { i in String(repeating: "This paragraph is deliberately long to probe the chunking ceiling and inference cost. ", count: 6) + "id \(i)." }),
    ]
    let repeats = 30
    var out: [String: Stats] = [:]
    print("engine=ONNX e5-small int8 (OrtBridge, query: 前缀)  dim=\(engine.dimension)  sig=\(engine.signature)")
    for bucket in buckets {
        let texts = (0..<repeats).map(bucket.make)
        _ = try engine.embed([texts[0]]) // 预热（含 CoreML 编译加载后的首次预测）
        var samples: [Double] = []
        var tokenCounts: [Int] = []
        let clock = ContinuousClock()
        for t in texts {
            var tokMs = 0.0
            var embMs = 0.0
            var d = try clock.measure { _ = try engine.tokenIDs(text: t) }
            tokMs = durationMs(d)
            d = try clock.measure { _ = try engine.embed([t]) }
            embMs = durationMs(d)
            _ = tokMs
            tokenCounts.append(try engine.tokenIDs(text: t).count)
            samples.append(embMs)
        }
        let st = stats(samples)
        let label = bucket.name.padding(toLength: 14, withPad: " ", startingAt: 0)
        print("tokens≈\(String(format: "%4d", tokenCounts.mean()))  mean \(String(format: "%6.2f", st.meanMs)) ms  p50 \(String(format: "%6.2f", st.p50Ms))  p95 \(String(format: "%6.2f", st.p95Ms))  (n=\(repeats))  [\(label)]")
    }
    // 批量路径（生产 embed([String]) 逐条循环）的吞吐：300 条混合文本
    let mixed = (0..<300).map { buckets[$0 % buckets.count].make($0) }
    _ = try engine.embed([mixed[0]])
    let clock = ContinuousClock()
    let bulk = try clock.measure { _ = try engine.embed(mixed) }
    let bulkMs = durationMs(bulk)
    print("bulk 300 chunks: \(String(format: "%.0f", bulkMs)) ms → \(String(format: "%.1f", 300.0 / (bulkMs / 1000.0))) chunks/s（生产逐条路径）")
}

extension Array where Element == Int {
    func mean() -> Int { self.reduce(0, +) / Swift.max(count, 1) }
}

// MARK: - scale 规模曲线

struct ScaleRow: Codable {
    var docs: Int
    var chunks: Int
    var indexMs: Double          // refreshSemanticIndex：切片 + 推理 + 落库
    var indexMsPerChunk: Double
    var regenerateMs: Double     // 候选生成（含 DB 读向量 + O(n²) 评分 + 落库）
    var regenerate2Ms: Double    // 第二遍（验证稳定性）
    var pendingLeads: Int
    var pendingDuplicates: Int
    var totalMs: Double
}

func runScale(corpus: String, sizes: [Int], dbRoot: String, out: String?) async throws {
    let engine = try await E5EmbeddingEngine()
    var rows: [ScaleRow] = []
    for size in sizes {
        let dir = URL(fileURLWithPath: corpus).appendingPathComponent("corpus-\(size)")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(files.count == size, "corpus-\(size) 文件数不符")
        var drafts: [Draft] = []
        for f in files {
            let content = try String(contentsOf: f, encoding: .utf8)
            drafts.append(Draft(title: f.lastPathComponent, content: content,
                                isEditable: true, sourceType: .localFile,
                                sourceLocation: f.path, sourceLabel: f.lastPathComponent))
        }
        // 全新隔离库
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dbRoot), withIntermediateDirectories: true)
        let dbPath = URL(fileURLWithPath: dbRoot).appendingPathComponent("bench-\(size).sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        let pool = try DatabasePool(path: dbPath)
        let database = try AppDatabase(pool: pool)
        let candidateEngine = CandidateEngine(database: database, embedder: engine)

        // 生产流程先落库再索引（indexChunk 外键指向 draft）；本基准只计引擎段，不含入库
        let persisted = drafts
        try await database.pool.write { db in
            for d in persisted { try d.insert(db) }
        }

        let clock = ContinuousClock()
        var t = try await clock.measure { try await database.refreshSemanticIndex(drafts: drafts, embedder: engine) }
        let indexMs = durationMs(t)
        t = try await clock.measure { try await candidateEngine.regenerate(drafts: drafts) }
        let regenMs = durationMs(t)
        t = try await clock.measure { try await candidateEngine.regenerate(drafts: drafts) }
        let regen2Ms = durationMs(t)

        let chunks = try await database.pool.read { try IndexChunk.fetchCount($0) }
        let report = try await candidateEngine.counts()
        let row = ScaleRow(
            docs: size, chunks: chunks, indexMs: indexMs,
            indexMsPerChunk: indexMs / Double(Swift.max(chunks, 1)),
            regenerateMs: regenMs, regenerate2Ms: regen2Ms,
            pendingLeads: report.pendingLeads, pendingDuplicates: report.pendingDuplicates,
            totalMs: indexMs + regenMs)
        rows.append(row)
        print(String(format: "n=%4d chunks=%5d  index %7.0f ms (%4.1f ms/chunk)  regen %7.0f ms (2nd %7.0f)  leads=%d dups=%d",
                     size, chunks, indexMs, row.indexMsPerChunk, regenMs, regen2Ms,
                     report.pendingLeads, report.pendingDuplicates))
    }
    if let out {
        let data = try JSONEncoder().encode(rows)
        try data.write(to: URL(fileURLWithPath: out))
        print("report → \(out)")
    }
}

// MARK: - variant 诊断：CoreML 计算单元 × 模型变体（只在本基准内加载模型，不改生产引擎）

func runVariant(modelArg: String?) async throws {
    let res = try EmbeddingModelLocator.defaultTokenizerFolder() // 生产同款资源目录（公开 API）
    let text = String(repeating: "本地优先的草稿收纳应用要把语义线索控制在可审的量级，", count: 3) + "编号7。"
    let units: [(String, MLComputeUnits)] = [
        ("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU), ("all", .all),
    ]
    var candidates: [(String, URL)] = []
    let compiled: [(String, URL)] = { () -> [(String, URL)] in
        // mlpackage 需先编译为 mlmodelc 才能加载（编译产物放临时目录，不计入计时）
        var urls: [(String, URL)] = []
        let res = try! EmbeddingModelLocator.defaultTokenizerFolder()
        for pkg in ["e5_small_int8.mlpackage", "e5_small_fp16.mlpackage"] {
            let u = res.appendingPathComponent(pkg, isDirectory: true)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            if let compiledURL = try? MLModel.compileModel(at: u) {
                urls.append((pkg, compiledURL))
            }
        }
        return urls
    }()
    if let modelArg {
        candidates.append((URL(fileURLWithPath: modelArg).lastPathComponent, URL(fileURLWithPath: modelArg)))
    }
    candidates.append(("e5_small.mlmodelc(生产)", try EmbeddingModelLocator.defaultModelURL()))
    for (pkgName, url) in compiled {
        candidates.append((pkgName + "(编译)", url))
    }
    for (name, url) in candidates {
        for (unitName, unit) in units {
            let config = MLModelConfiguration()
            config.computeUnits = unit
            let model: MLModel
            do {
                model = try MLModel(contentsOf: url, configuration: config)
            } catch {
                print("\(name) + \(unitName): 加载失败 — \(error.localizedDescription)")
                continue
            }
            func predict() throws -> Double {
                var ids = try TokenizerBridge.shared.tokenIDs(text: text, folder: res)
                // 固定 shape 模型：按模型描述把序列 pad 到目标长度（1=<pad>，mask=0）
                var seqLen = ids.count
                if let shape = model.modelDescription.inputDescriptionsByName["input_ids"]?
                    .multiArrayConstraint?.shape, shape.count == 2, shape[1].intValue > 0 {
                    seqLen = shape[1].intValue
                }
                if ids.count < seqLen {
                    ids.append(contentsOf: Array(repeating: 1, count: seqLen - ids.count))
                } else if ids.count > seqLen {
                    ids = Array(ids[0..<seqLen])
                }
                let realCount = ids.count
                let inputIds = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
                for (i, v) in ids.enumerated() { inputIds[i] = NSNumber(value: v) }
                let mask = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
                for i in 0..<seqLen { mask[i] = NSNumber(value: i < realCount ? 1 : 0) }
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": try MLFeatureValue(multiArray: inputIds),
                    "attention_mask": try MLFeatureValue(multiArray: mask),
                ])
                let clock = ContinuousClock()
                let d = try clock.measure { _ = try model.prediction(from: input) }
                return durationMs(d)
            }
            do {
                _ = try predict() // 预热（含编译）
                var samples: [Double] = []
                for _ in 0..<10 { samples.append(try predict()) }
                let st = stats(samples)
                let label = name.padding(toLength: 28, withPad: " ", startingAt: 0)
                let unitLabel = unitName.padding(toLength: 9, withPad: " ", startingAt: 0)
                print("[\(label)] + [\(unitLabel)] mean \(String(format: "%8.2f", st.meanMs)) ms  p50 \(String(format: "%8.2f", st.p50Ms))  (n=10)")
            } catch {
                print("\(name) + \(unitName): 预测失败 — \(error.localizedDescription)")
            }
        }
    }
}

/// 直接用 swift-transformers 产 token（与生产 E5EmbeddingEngine 同库同配置）。
final class TokenizerBridge: @unchecked Sendable {
    static let shared = TokenizerBridge()
    private var tokenizer: (any Tokenizer)?
    private let lock = NSLock()
    func tokenIDs(text: String, folder: URL) throws -> [Int] {
        lock.lock(); defer { lock.unlock() }
        if tokenizer == nil {
            var configJSON = try JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json")),
                options: [.json5Allowed]) as! [NSString: Any]
            configJSON["tokenizer_class"] = "T5Tokenizer"
            let tokenizerConfig = Config(configJSON)
            let tokenizerDataJSON = try JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("tokenizer.json")),
                options: [.json5Allowed]) as! [NSString: Any]
            tokenizer = try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig,
                                                tokenizerData: Config(tokenizerDataJSON))
        }
        return try tokenizer!.encode(text: text)
    }
}

/// regen 分相复刻：与 CandidateEngine.regenerate 相同的循环形状，定位时间都花在哪个相。
/// 只读生产 API 与已填充的库；不写 candidatePair（避免干扰）。
func runRegenPhases(dbPath: String, corpus: String, size: Int) async throws {
    let pool = try DatabasePool(path: dbPath)
    let database = try AppDatabase(pool: pool)
    let dir = URL(fileURLWithPath: corpus).appendingPathComponent("corpus-\(size)")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var built: [Draft] = []
    for f in files.prefix(size) {
        built.append(Draft(title: f.lastPathComponent,
                           content: try String(contentsOf: f, encoding: .utf8),
                           isEditable: true, sourceType: .localFile,
                           sourceLocation: f.path, sourceLabel: f.lastPathComponent))
    }
    let persisted: [Draft] = try await database.pool.read { db in
        try Draft.order(Column("title")).fetchAll(db)
    }
    precondition(persisted.count >= size, "库内草稿不足：\(persisted.count)")
    let drafts = Array(persisted.prefix(size))

    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double { durationMs(d) }

    // 相 1：chunksByDraft()（DB 读 + blob 解码）
    var t = try await clock.measure { _ = try await database.chunksByDraft() }
    print(String(format: "phase1 chunksByDraft:          %8.1f ms", ms(t)))
    let chunksByDraft = try await database.chunksByDraft()

    // 相 0：每查询常数基线（SELECT 1 × 100）
    t = try await clock.measure {
        for _ in 0..<100 {
            _ = try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
        }
    }
    print(String(format: "phase0 SELECT 1 ×100:          %8.1f ms（每查询常数）", ms(t)))

    // 相 2：对循环（.vector 解码 + 标量余弦 + 阈值）——与 regenerate 相同的循环形状
    var cosineCalls = 0
    var bestLocal = -Double.infinity
    t = try await clock.measure {
        for i in 0..<drafts.count {
            for j in (i + 1)..<drafts.count {
                let a = chunksByDraft[drafts[i].id] ?? []
                let b = chunksByDraft[drafts[j].id] ?? []
                for ca in a {
                    for cb in b {
                        cosineCalls += 1
                        let va = ca.vector, vb = cb.vector
                        var dot: Float = 0, na: Float = 0, nb: Float = 0
                        for k in 0..<min(va.count, vb.count) {
                            dot += va[k] * vb[k]; na += va[k] * va[k]; nb += vb[k] * vb[k]
                        }
                        let s = Double(dot / Swift.max(sqrt(na) * sqrt(nb), 1e-12))
                        if s > bestLocal { bestLocal = s }
                    }
                }
            }
        }
    }
    print(String(format: "phase2 对循环（%d 次余弦）:    %8.1f ms  最高分 %.4f", cosineCalls, ms(t), bestLocal))

    // 相 3：字面信号（正则分词 + jaccard，每对都算一遍）
    t = try await clock.measure {
        for i in 0..<drafts.count {
            for j in (i + 1)..<drafts.count {
                _ = LiteralSignals.jaccard(
                    LiteralSignals.tokens(drafts[i].content ?? ""),
                    LiteralSignals.tokens(drafts[j].content ?? ""))
            }
        }
    }
    print(String(format: "phase3 字面信号（全部对）:      %8.1f ms", ms(t)))

    // 相 4：逐对存在性 SELECT（与 regenerate 相同的 filter 形状）
    var selHits = 0
    t = try await clock.measure {
        selHits = try await database.pool.read { db -> Int in
            var hits = 0
            for i in 0..<drafts.count {
                for j in (i + 1)..<drafts.count {
                    let hit = try CandidatePair
                        .filter((Column("draftA") == drafts[i].id && Column("draftB") == drafts[j].id)
                            || (Column("draftA") == drafts[j].id && Column("draftB") == drafts[i].id))
                        .order(Column("createdAt").desc)
                        .fetchOne(db)
                    if hit != nil { hits += 1 }
                }
            }
            return hits
        }
    }
    print(String(format: "phase4 逐对 SELECT（命中 %d）:  %8.1f ms", selHits, ms(t)))
}
// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "embed":
        try await runEmbed()
    case "regen":
        guard let dbPath = value("--db-path", in: args), let corpus = value("--corpus", in: args), let size = Int(value("--size", in: args) ?? "30") else {
            fputs("用法: dz-bench regen --db-path P.sqlite --corpus DIR --size N\n", stderr); exit(2)
        }
        try await runRegenPhases(dbPath: dbPath, corpus: corpus, size: size)
    case "variant":
        try await runVariant(modelArg: value("--model", in: args))
    case "scale":
        guard let corpus = value("--corpus", in: args),
              let dbRoot = value("--db", in: args) else {
            fputs("用法: dz-bench scale --corpus DIR --sizes 30,100,300,1000 --db DIR [--out JSON]\n", stderr)
            exit(2)
        }
        let sizes = (value("--sizes", in: args) ?? "30,100,300,1000")
            .split(separator: ",").compactMap { Int($0) }
        try await runScale(corpus: corpus, sizes: sizes, dbRoot: dbRoot,
                           out: value("--out", in: args))
    default:
        fputs("用法: dz-bench embed | scale --corpus DIR --sizes N,N --db DIR [--out JSON]\n", stderr)
        exit(2)
    }
} catch {
    fputs("FATAL: \(error)\n", stderr)
    exit(1)
}
