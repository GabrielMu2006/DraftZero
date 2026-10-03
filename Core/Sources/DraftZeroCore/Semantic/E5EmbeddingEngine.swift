import Foundation
import Tokenizers
import Hub
import OrtBridge

/// multilingual-e5-small ONNX int8 推理引擎（2026-10 换栈：OrtBridge C 桥 + ONNX Runtime）。
/// 与 Windows C# E5OnnxEmbedder 同口径："query: " 前缀 + 512 截断 + attention-mask
/// mean pooling + L2 归一化、384 维（池化与归一化在 C 桥内完成）。
/// 换栈同时修复了两处历史偏差：原 CoreML 路径动态 shape 在 macOS 26 上病态缓慢；
/// 原 CoreML 路径漏加 "query: " 前缀（与 Windows 及 T-011 验证配方不一致）。
public final class E5EmbeddingEngine: TextEmbedding, @unchecked Sendable {

    private let engine: UnsafeMutableRawPointer
    private let tokenizer: any Tokenizer
    public let dimension: Int
    /// 索引签名：签名不同的已索引切片在刷新时自动重嵌。
    public let signature: String

    public static let queryPrefix = "query: "
    public static let maxTokens = 512

    public init(modelURL: URL, tokenizerFolder: URL, dylibURL: URL) throws {
        var err = [CChar](repeating: 0, count: 512)
        var engine: UnsafeMutableRawPointer?
        let rc = modelURL.path.withCString { modelPath in
            dylibURL.path.withCString { dylibPath in
                ort_engine_open(dylibPath, modelPath, Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
                                &engine, &err, 512)
            }
        }
        guard rc == 0, let engine else {
            let message = String(cString: err)
            throw SemanticError.inferenceFailed(message.isEmpty ? "ONNX 会话创建失败" : message)
        }
        self.engine = engine
        self.signature = String(cString: ort_engine_signature())
        self.tokenizer = try Self.makeTokenizer(folder: tokenizerFolder)
        self.dimension = 384
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

    public convenience init() throws {
        try self.init(modelURL: EmbeddingModelLocator.defaultModelURL(),
                      tokenizerFolder: EmbeddingModelLocator.defaultTokenizerFolder(),
                      dylibURL: EmbeddingModelLocator.defaultDylibURL())
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try texts.map { text in
            var ids = try tokenIDs(text: Self.queryPrefix + text)
            if ids.count > Self.maxTokens {
                ids = Array(ids[0..<Self.maxTokens])
            }
            return try embedSingle(ids: ids)
        }
    }

    /// 原始 token ID 序列（含 <s>/</s>，未截断、未加前缀）。跨平台分词对齐用。
    public func tokenIDs(text: String) throws -> [Int] {
        try tokenizer.encode(text: text)
    }

    private func embedSingle(ids: [Int]) throws -> [Float] {
        let n = max(ids.count, 1)
        var idBuf = [Int64](repeating: 0, count: n)
        var maskBuf = [Int64](repeating: 0, count: n)
        for i in 0..<n {
            idBuf[i] = i < ids.count ? Int64(ids[i]) : 1 // 1 = <pad>
            maskBuf[i] = i < ids.count ? 1 : 0
        }
        var out = [Float](repeating: 0, count: dimension)
        var err = [CChar](repeating: 0, count: 512)
        let rc = idBuf.withUnsafeMutableBufferPointer { idPtr in
            maskBuf.withUnsafeMutableBufferPointer { maskPtr in
                out.withUnsafeMutableBufferPointer { outPtr in
                    ort_embed(engine, idPtr.baseAddress!, maskPtr.baseAddress!, Int32(n),
                              outPtr.baseAddress!, &err, 512)
                }
            }
        }
        guard rc == 0 else {
            let message = String(cString: err)
            throw SemanticError.inferenceFailed(message.isEmpty ? "ONNX 推理失败" : message)
        }
        return out
    }

    deinit {
        ort_engine_close(engine)
    }
}
