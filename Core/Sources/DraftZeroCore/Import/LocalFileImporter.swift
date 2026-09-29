import Foundation

/// 本地文件导入器（R-001）。逐项处理，单件失败不影响同批其他文件；
/// 原文件只读不写；文本副本存入工作区数据库。
public struct LocalFileImporter: Sendable {

    public static let supportedExtensions = ["txt", "md", "markdown", "text", "pdf"]

    public let database: AppDatabase
    public let snapshotsDirectory: URL

    public init(database: AppDatabase, snapshotsDirectory: URL) {
        self.database = database
        self.snapshotsDirectory = snapshotsDirectory
    }

    /// 批量导入：逐项报告，一项失败不影响其他项（R-001 验收）。
    public func importFiles(at urls: [URL]) async -> [ImportedItem] {
        var results: [ImportedItem] = []
        results.reserveCapacity(urls.count)
        for url in urls {
            let outcome = await importFile(at: url)
            results.append(ImportedItem(
                displayName: url.lastPathComponent,
                source: .localFile(url),
                outcome: outcome))
        }
        return results
    }

    /// - Parameter allowDuplicate: 用户对重复提示选择"另存新快照"后置 true 重试。
    public func importFile(at url: URL, allowDuplicate: Bool = false) async -> ImportOutcome {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            return .failure(reason: "不支持的文件类型：.\(ext.isEmpty ? "（无扩展名）" : ext)")
        }

        // 拖拽/打开面板给出的文件需要显式取得访问权（沙盒）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(reason: "文件不存在或无法访问：\(url.lastPathComponent)")
        }

        switch ext {
        case "pdf":
            return await importPDF(at: url, allowDuplicate: allowDuplicate)
        default:
            return await importTextFile(at: url, allowDuplicate: allowDuplicate)
        }
    }

    private func importTextFile(at url: URL, allowDuplicate: Bool) async -> ImportOutcome {
        let text: String
        do {
            text = try TextReading.readText(at: url)
        } catch {
            return .failure(reason: error.localizedDescription)
        }
        // 完全空白的文本不生成空草稿。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(reason: "文件没有可读取的正文")
        }

        let fingerprint = TextReading.fingerprint(of: text)
        if !allowDuplicate,
           let existing = try? await database.findExistingDraft(
               sourceLocation: url.path, fingerprint: fingerprint) {
            return .duplicate(existing: existing)
        }

        let title = TextReading.extractTitle(
            from: text, fallback: url.deletingPathExtension().lastPathComponent)
        let draft = Draft(
            title: title,
            content: text,
            isEditable: true,
            sourceType: .localFile,
            sourceLocation: url.path,
            sourceLabel: url.lastPathComponent,
            fingerprint: fingerprint)
        do {
            let saved = try await database.insertDraft(draft, initialVersion: true)
            return .success(saved)
        } catch {
            return .failure(reason: "保存失败：\(error.localizedDescription)")
        }
    }

    private func importPDF(at url: URL, allowDuplicate: Bool) async -> ImportOutcome {
        let extraction: PDFTextExtractor.ExtractionResult
        do {
            extraction = try PDFTextExtractor.extract(from: url)
        } catch {
            return .failure(reason: error.localizedDescription)
        }

        // 先落盘快照，再入库；入库失败时清理落盘文件。
        let destination = snapshotsDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return .failure(reason: "无法复制 PDF 快照：\(error.localizedDescription)")
        }

        let fingerprint = extraction.text.map { TextReading.fingerprint(of: $0) }
        if !allowDuplicate,
           let existing = try? await database.findExistingDraft(
               sourceLocation: url.path, fingerprint: fingerprint) {
            try? FileManager.default.removeItem(at: destination)
            return .duplicate(existing: existing)
        }

        let draft = Draft(
            title: url.deletingPathExtension().lastPathComponent,
            content: extraction.text,
            isEditable: false,
            hasExtractableText: extraction.hasSelectableText,
            sourceType: .pdf,
            sourceLocation: url.path,
            sourceLabel: url.lastPathComponent,
            snapshotFileURL: destination.path,
            fingerprint: fingerprint)
        do {
            let saved = try await database.insertDraft(draft, initialVersion: true)
            return .success(saved)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(reason: "保存失败：\(error.localizedDescription)")
        }
    }
}
