import Foundation
import CryptoKit

/// 导入相关的纯文本处理：编码读取、标题提取、归一化指纹。
public enum TextReading {

    public enum ReadingError: LocalizedError, Equatable {
        case unreadableEncoding

        public var errorDescription: String? {
            switch self {
            case .unreadableEncoding: "无法识别文件编码（尝试过 UTF-8 与 GB18030）"
            }
        }
    }

    /// TXT/Markdown 读取：优先 UTF-8，失败回退 GB18030（中文用户常见旧文件）。
    public static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        throw ReadingError.unreadableEncoding
    }

    /// 标题：Markdown 一级标题优先，否则第一行非空文字，截到 80 字。
    public static func extractTitle(from text: String, fallback: String) -> String {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return String(heading.prefix(80)) }
            }
            if !line.isEmpty { return String(line.prefix(80)) }
        }
        return fallback.isEmpty ? "未命名草稿" : fallback
    }

    /// 归一化正文指纹：小写化、去掉标点与空白后取 SHA-256。
    /// 仅用于"可能重复"提示与重复来源检测，不参与归组排序。
    public static func fingerprint(of text: String) -> String {
        let kept = String.UnicodeScalarView(
            text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let normalized = String(kept).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
