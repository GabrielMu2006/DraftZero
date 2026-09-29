import Foundation
import PDFKit

/// PDF 文本提取（R-001/R-002 基础）：可选中文字的 PDF 参与关联；
/// 扫描版/无文字 PDF 仍保留快照供阅读，但标记"无可用于关联的文字"。
public enum PDFTextExtractor {

    public struct ExtractionResult: Sendable, Equatable {
        public let text: String?
        public let pageCount: Int
        public let hasSelectableText: Bool
    }

    /// 低于该字符数视为无可用正文。
    static let minimumExtractableCharacters = 20

    public enum ExtractionError: LocalizedError, Equatable {
        case notReadablePDF

        public var errorDescription: String? {
            switch self {
            case .notReadablePDF: "不是可读取的 PDF 文件"
            }
        }
    }

    public static func extract(from url: URL) throws -> ExtractionResult {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.notReadablePDF
        }
        var pieces: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                pieces.append(pageText)
            }
        }
        let text = pieces.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = text.count >= minimumExtractableCharacters
        return ExtractionResult(
            text: hasText ? text : nil,
            pageCount: document.pageCount,
            hasSelectableText: hasText)
    }
}
