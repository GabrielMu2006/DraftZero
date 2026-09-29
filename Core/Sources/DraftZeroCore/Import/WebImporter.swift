import Foundation

/// 网页快照导入器（R-002）：保存可阅读正文与原 URL；断网后仍可阅读；
/// 外部页面后续变化不会改写快照。
public struct WebImporter: Sendable {

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let database: AppDatabase
    public let fetch: Fetch

    public init(database: AppDatabase, fetch: Fetch? = nil) {
        self.database = database
        self.fetch = fetch ?? Self.defaultFetch
    }

    public static let defaultFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: HTTPUserAgent.stamped(request))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func importWebPage(url: URL, allowDuplicate: Bool = false) async -> ImportOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            return .failure(reason: "网络错误，无法读取网页：\(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode) else {
            return .failure(reason: "网页返回错误（HTTP \(response.statusCode)）")
        }
        let mime = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let readable = mime.contains("text/html") || mime.contains("text/plain")
            || mime.contains("xhtml") || mime.isEmpty
        guard readable else {
            return .failure(reason: "不是可读取的网页（内容类型：\(mime)）")
        }

        guard let page = WebPageExtractor.extract(htmlData: data) else {
            return .failure(reason: "无法提取正文：可能是登录墙、纯媒体页或非常规页面")
        }

        // 去掉锚点后作为来源标识（同一页面的不同锚点视为同一来源）。
        var normalized = url
        normalized = normalized.absoluteString.split(separator: "#").first
            .map { URL(string: String($0)) ?? url } ?? url

        let fingerprint = TextReading.fingerprint(of: page.text)
        if !allowDuplicate,
           let existing = try? await database.findExistingDraft(
               sourceLocation: normalized.absoluteString, fingerprint: fingerprint) {
            return .duplicate(existing: existing)
        }

        let title = page.title.isEmpty
            ? (url.host ?? "网页快照")
            : String(page.title.prefix(80))
        let draft = Draft(
            title: title,
            content: page.text,
            isEditable: false,
            sourceType: .web,
            sourceLocation: normalized.absoluteString,
            sourceLabel: url.host,
            fingerprint: fingerprint)
        do {
            let saved = try await database.insertDraft(draft, initialVersion: true)
            return .success(saved)
        } catch {
            return .failure(reason: "保存失败：\(error.localizedDescription)")
        }
    }
}
