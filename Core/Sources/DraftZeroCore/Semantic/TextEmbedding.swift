import Foundation

/// 文本向量器抽象。生产实现是随应用分发的 multilingual-e5-small（ONNX int8，
/// 经 OrtBridge C 桥推理）；测试注入确定性假向量器，离线可跑。
public protocol TextEmbedding: Sendable {
    var dimension: Int { get }
    /// 引擎签名（模型 + 前缀约定版本）。签名变化时索引自动重嵌（SemanticIndex）。
    var signature: String { get }
    /// 返回与输入等长的 L2 归一化向量。
    func embed(_ texts: [String]) throws -> [[Float]]
    func embed(_ text: String) throws -> [Float]
}

extension TextEmbedding {
    public func embed(_ text: String) throws -> [Float] {
        try embed([text])[0]
    }
}

/// 默认模型位置：包资源内的 ONNX int8 模型与 ONNX Runtime dylib（2026-10 换栈，
/// 替换原 CoreML 动态 shape 模型——该路径在 macOS 26 上病态缓慢，证据见
/// Windows/evidence/ENGINE-PERF-BASELINE-2026-10-03.md）。
public enum EmbeddingModelLocator {
    public static func defaultModelURL() throws -> URL {
        try onnxruntimeDir().appendingPathComponent("model_quantized.onnx")
    }

    public static func defaultDylibURL() throws -> URL {
        try onnxruntimeDir().appendingPathComponent("libonnxruntime.dylib")
    }

    public static func defaultTokenizerFolder() throws -> URL {
        guard let dir = Bundle.module.url(forResource: "e5-small-onnx", withExtension: nil) else {
            throw SemanticError.modelMissing
        }
        return dir
    }

    private static func onnxruntimeDir() throws -> URL {
        try defaultTokenizerFolder().appendingPathComponent("onnxruntime", isDirectory: true)
    }
}

public enum SemanticError: LocalizedError, Equatable {
    case modelMissing
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing: "本机语义模型缺失（应用包损坏），可重建索引但语义线索暂不可用"
        case .inferenceFailed(let detail): "本机语义推理失败：\(detail)"
        }
    }
}
