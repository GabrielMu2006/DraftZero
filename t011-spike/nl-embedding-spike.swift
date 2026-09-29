// T-011 Spike A: Apple NLEmbedding sentence embedding feasibility for Draft Zero
// Questions to answer:
//   1. Is sentenceEmbedding available offline for zh-Hans / en on this Mac?
//   2. Vector dimension, and does it embed Chinese text with the Chinese model?
//   3. Can it separate same-topic paraphrase pairs from unrelated pairs (zh & en)?
//   4. Cross-language (zh vs en) similarity - usually impossible with per-language models.

import Foundation
import NaturalLanguage

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
    }
    return dot / (Foundation.sqrt(na) * Foundation.sqrt(nb) + 1e-12)
}

print("== NLEmbedding sentence embedding availability ==")
let langs: [(NLLanguage, String)] = [
    (.simplifiedChinese, "zh-Hans"),
    (.english, "en"),
    (.traditionalChinese, "zh-Hant"),
]
var embeddings: [NLLanguage: NLEmbedding] = [:]
for (lang, label) in langs {
    let emb = NLEmbedding.sentenceEmbedding(for: lang)
    if let emb = emb {
        // Probe dimension with a sample string
        let probe = emb.vector(for: "测试 probe")
        print("\(label): AVAILABLE, dim=\(probe?.count ?? -1)")
        embeddings[lang] = emb
    } else {
        print("\(label): nil (model unavailable)")
    }
}

struct Pair { let a: String; let b: String; let expected: String; let note: String }

let zhPairs: [Pair] = [
    (Pair(a: "我们用一组标准化任务来测试大模型的推理能力，并按难度分级打分。",
          b: "这个评测集衡量语言模型在多步推理任务上的表现，每档任务有独立的评分标准。",
          expected: "same-topic", note: "zh paraphrase: benchmark/评测")),
    (Pair(a: "我们用一组标准化任务来测试大模型的推理能力，并按难度分级打分。",
          b: "给不同模型出同一批测试题，比较它们的得分和失败案例，再汇总成报告。",
          expected: "same-topic", note: "zh related wording")),
    (Pair(a: "我们用一组标准化任务来测试大模型的推理能力，并按难度分级打分。",
          b: "周末去郊外烧烤，记得提前一天买好木炭和腌制好的肉。",
          expected: "different", note: "zh unrelated")),
    (Pair(a: "小说开头：雨夜，她推开旧书店的门，风铃在头顶轻响。",
          b: "他又检查了一遍门锁，才敢在深夜的巷子里快步走开。",
          expected: "same-topic", note: "zh novel fragments")),
    (Pair(a: "小说开头：雨夜，她推开旧书店的门，风铃在头顶轻响。",
          b: "部署脚本要在凌晨三点跑批，先停写入再重建索引。",
          expected: "different", note: "zh novel vs tech")),
]

let enPairs: [Pair] = [
    (Pair(a: "We grade language models on a shared set of reasoning tasks, tiered by difficulty.",
          b: "The benchmark measures how well LLMs handle multi-step problems, with per-tier scoring rubrics.",
          expected: "same-topic", note: "en paraphrase")),
    (Pair(a: "We grade language models on a shared set of reasoning tasks, tiered by difficulty.",
          b: "Buy charcoal and marinated meat the day before the weekend barbecue.",
          expected: "different", note: "en unrelated")),
]

print("\n== Same-language pair similarity (built-in cosine distance) ==")
func runPairs(_ pairs: [Pair], lang: NLLanguage) {
    guard let emb = embeddings[lang] else { return }
    for p in pairs {
        let va = emb.vector(for: p.a)
        let vb = emb.vector(for: p.b)
        if let va = va, let vb = vb {
            let cos = cosine(va, vb)
            let d = emb.distance(between: p.a, and: p.b, distanceType: .cosine)
            print("[\(lang.rawValue)] expect=\(p.expected) cos=\(String(format: "%.3f", cos)) builtInDist=\(String(format: "%.3f", d)) -- \(p.note)")
        } else {
            print("[\(lang.rawValue)] vector nil for pair -- \(p.note)")
        }
    }
}
runPairs(zhPairs, lang: .simplifiedChinese)
runPairs(enPairs, lang: .english)

print("\n== Cross-language probe (zh text vs en model, and vice versa) ==")
if let en = embeddings[.english], let zh = embeddings[.simplifiedChinese] {
    let zhText = "我们用一组标准化任务来测试大模型的推理能力。"
    let enText = "We grade language models on a shared set of reasoning tasks."
    print("zh text -> en model vector: \(en.vector(for: zhText) == nil ? "nil" : "non-nil")")
    print("en text -> zh model vector: \(zh.vector(for: enText) == nil ? "nil" : "non-nil")")
}

print("\n== Word-level embedding availability (fallback signal) ==")
for (lang, label) in langs {
    let w = NLEmbedding.wordEmbedding(for: lang)
    print("\(label) wordEmbedding: \(w != nil ? "AVAILABLE dim=\(w?.dimension ?? -1)" : "nil")")
}
