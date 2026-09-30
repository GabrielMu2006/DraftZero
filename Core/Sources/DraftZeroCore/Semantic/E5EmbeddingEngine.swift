import Foundation
import CoreML
import Tokenizers
import Hub

/// multilingual-e5-small 本机推理引擎（CoreML 模型，随应用分发，断网可用）。
/// 与 T-011 验证路径一致："query: " 前缀 + attention-mask mean pooling + L2 归一化；
/// 模型经 convert_coreml.py 与 ONNX 输出做过逐句一致性校验（余弦 ≥ 0.995）。
public final class E5EmbeddingEngine: TextEmbedding, @unchecked Sendable {

    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let outputName: String
    public let dimension: Int

    public static let queryPrefix = "query: "
    public static let maxTokens = 512

    public init(modelURL: URL, tokenizerFolder: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly // 与一致性校验一致；ANE 版本经校验后再启用
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        tokenizer = try Self.makeTokenizer(folder: tokenizerFolder)
        if let name = model.modelDescription.outputDescriptionsByName.keys.sorted().first {
            outputName = name
        } else {
            throw SemanticError.inferenceFailed("模型没有输出描述")
        }
        dimension = 384
    }

    /// e5-small 的分词模型是 Unigram（XLM-R 规范），swift-transformers 未收录
    /// "XLMRobertaTokenizer" 类名；T5Tokenizer 同为 Unigram 实现，而 normalizer、
    /// pre-tokenizer、post-processor（<s>…</s> 模板）均取自随包的 tokenizer.json，
    /// 因此改写类名不影响编码结果（已与 Python 端逐句校验一致）。
    private static func makeTokenizer(folder: URL) throws -> any Tokenizer {
        var configJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json")),
            options: [.json5Allowed]) as! [NSString: Any]
        configJSON["tokenizer_class"] = "T5Tokenizer"
        let tokenizerConfig = Config(configJSON)
        let tokenizerDataJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("tokenizer.json")),
            options: [.json5Allowed]) as! [NSString: Any]
        let tokenizerData = Config(tokenizerDataJSON)
        return try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }

    public convenience init() async throws {
        try await self.init(
            modelURL: EmbeddingModelLocator.defaultModelURL(),
            tokenizerFolder: EmbeddingModelLocator.defaultTokenizerFolder())
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try texts.map { text in
            var ids = try tokenIDs(text: text)
            if ids.count > Self.maxTokens {
                ids = Array(ids[0..<Self.maxTokens])
            }
            return try embedSingle(ids: ids)
        }
    }

    /// 原始 token ID 序列（含 <s>/</s>，未截断）。V0.2.0 M0 黄金样本与跨平台对齐用。
    public func tokenIDs(text: String) throws -> [Int] {
        try tokenizer.encode(text: text)
    }

    private func embedSingle(ids: [Int]) throws -> [Float] {
        let seqLen = max(ids.count, 1)
        let inputIds = try Self.int32Array(ids.map { Int32(truncatingIfNeeded: $0) })
        let attentionMask = try Self.int32Array(Array(repeating: 1, count: seqLen))

        let inputDict: [String: MLFeatureValue] = [
            "input_ids": try MLFeatureValue(multiArray: inputIds),
            "attention_mask": try MLFeatureValue(multiArray: attentionMask),
        ]
        let input = try MLDictionaryFeatureProvider(dictionary: inputDict)
        let output = try model.prediction(from: input)
        guard let embedding = output.featureValue(for: outputName)?.multiArrayValue else {
            throw SemanticError.inferenceFailed("缺少 \(outputName) 输出")
        }
        guard embedding.count == dimension else {
            throw SemanticError.inferenceFailed("输出维度异常：\(embedding.count) ≠ \(dimension)")
        }
        // 模型内已完成 mask mean pooling 与 L2 归一化。
        return (0..<dimension).map { embedding[$0].floatValue }
    }

    private static func int32Array(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        return array
    }
}
