import Foundation

/// 网页正文提取（R-002）：去脚本/样式与明显导航页脚后保留标题与正文。
/// V1 采用"标签剔除 + NSAttributedString 渲染"的启发式提取；
/// 登录墙/纯媒体页提取不出正文时会得到过短文本，由调用方判为失败。
public enum WebPageExtractor {

    public struct Page: Sendable, Equatable {
        public let title: String
        public let text: String
    }

    /// 提取结果正文低于该字符数视为无可读正文。
    static let minimumBodyCharacters = 50

    static let strippedTags = ["script", "style", "nav", "header", "footer", "aside", "noscript", "form"]

    public static func extract(htmlData: Data) -> Page? {
        guard var html = decode(htmlData) else { return nil }
        let title = extractTitle(from: html)

        // 去掉 script/style 与明显结构性区域（启发式，兼顾常见站点）。
        for tag in strippedTags {
            html = removeTag(tag, in: html)
        }

        // 显式声明 UTF-8：旧版 HTML 解析器在无 charset 时会按系统旧编码误读中文。
        let marked = "<meta charset=\"utf-8\">" + html
        var attributes: NSDictionary?
        guard let attributed = try? NSAttributedString(
            data: Data(marked.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .textEncodingName: "utf-8",
            ],
            documentAttributes: &attributes) else {
            return nil
        }
        let text = attributed.string
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumBodyCharacters else { return nil }
        return Page(title: title, text: text)
    }

    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030)
    }

    static func extractTitle(from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<title[^>]*>(.*?)</title>") else { return "" }
        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, range: range),
           let tagRange = Range(match.range(at: 1), in: html) {
            let raw = String(html[tagRange])
            if let decoded = decodeHTMLChunk(raw) {
                return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 标题里的 HTML 实体（&amp; 等）交给 NSAttributedString 渲染解码。
    static func decodeHTMLChunk(_ chunk: String) -> String? {
        var attributes: NSDictionary?
        guard let attributed = try? NSAttributedString(
            data: Data("<meta charset=\"utf-8\"><span>\(chunk)</span>".utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .textEncodingName: "utf-8",
            ],
            documentAttributes: &attributes) else {
            return nil
        }
        return attributed.string
    }

    static func removeTag(_ tag: String, in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<\(tag)[^>]*>[\\s\\S]*?</\(tag)>|(?i)<\(tag)[^>]*/>") else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }
}
