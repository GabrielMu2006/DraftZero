import Foundation

/// 文本向量器抽象。生产实现是随应用分发的 multilingual-e5-small（ONNX，量化）；
/// 测试注入确定性假向量器，离线可跑。
public protocol TextEmbedding: Sendable {
    var dimension: Int { get }
    /// 返回与输入等长的 L2 归一化向量。
    func embed(_ texts: [String]) throws -> [[Float]]
    func embed(_ text: String) throws -> [Float]
}

extension TextEmbedding {
    public func embed(_ text: String) throws -> [Float] {
        try embed([text])[0]
    }
}

/// 默认模型位置：包资源内的 CoreML 模型（int8 权重，113MB）。
public enum EmbeddingModelLocator {
    public static func defaultModelURL() throws -> URL {
        guard let dir = Bundle.module.url(forResource: "e5-small-onnx", withExtension: nil) else {
            throw SemanticError.modelMissing
        }
        return dir.appendingPathComponent("e5_small.mlmodelc", isDirectory: true)
    }

    public static func defaultTokenizerFolder() throws -> URL {
        guard let dir = Bundle.module.url(forResource: "e5-small-onnx", withExtension: nil) else {
            throw SemanticError.modelMissing
        }
        return dir
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
