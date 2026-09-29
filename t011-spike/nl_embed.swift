// T-011 Spike: embed every chunk with Apple NLEmbedding (zh-Hans & en sentence models).
// Reads chunks.json, writes nl.json with vectors from BOTH models per chunk,
// so cross-language behaviour can be measured separately.

import Foundation
import NaturalLanguage

struct Chunk: Codable { let id: String; let doc: String; let text: String }

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
    return dot / (Foundation.sqrt(na) * Foundation.sqrt(nb) + 1e-12)
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let data = try Data(contentsOf: URL(fileURLWithPath: here + "/chunks.json"))
let chunks = try JSONDecoder().decode([Chunk].self, from: data)

guard let zh = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese),
      let en = NLEmbedding.sentenceEmbedding(for: .english) else {
    FileHandle.standardError.write("sentence embedding models unavailable".data(using: .utf8)!)
    exit(1)
}

let recognizer = NLLanguageRecognizer()
var result: [String: [String: [Double]]] = [:]
var detected: [String: String] = [:]

for (i, c) in chunks.enumerated() {
    recognizer.reset()
    recognizer.processString(c.text)
    let lang = recognizer.dominantLanguage?.rawValue ?? "und"
    detected[c.id] = lang
    var entry: [String: [Double]] = [:]
    if let v = zh.vector(for: c.text) { entry["zh"] = v }
    if let v = en.vector(for: c.text) { entry["en"] = v }
    result[c.id] = entry
    if i % 20 == 0 { FileHandle.standardError.write("embedded \(i)/\(chunks.count)\n".data(using: .utf8)!) }
}

let out: [String: Any] = ["vectors": result, "detected": detected]
let outData = try JSONSerialization.data(withJSONObject: out)
try outData.write(to: URL(fileURLWithPath: here + "/nl.json"))
print("wrote nl.json for \(chunks.count) chunks")
