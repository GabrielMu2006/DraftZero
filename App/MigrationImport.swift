import AppKit
import DraftZeroCore

/// V0.2.0 D-002 双向迁移：Mac 端导入 Windows 导出的 .dzarchive。
/// 仅允许空工作区；先整体校验（manifest SHA/引用完整性），PDF 落位后
/// 单事务写入（失败零部分写入）；导入后由应用重建语义索引。
enum MigrationImport {

    /// 执行导入；返回可读的结果说明（成功含条目计数，失败含原因）。
    @MainActor
    static func runImport(database: AppDatabase?, snapshotsDirectory: URL, archiveURL: URL) async -> String {
        guard let database else {
            return "工作区尚未就绪，请稍后重试"
        }
        do {
            let empty = try await DzArchiveImporter.isWorkspaceEmpty(database)
            guard empty else {
                return "导入失败：当前 Mac 工作区已有内容。迁移仅支持导入到空工作区；请先备份或另建空工作区（不做自动合并）。"
            }
            let counts = try await DzArchiveImporter.importArchive(
                archivePath: archiveURL.path,
                into: database,
                snapshotsDirectory: snapshotsDirectory)
            return "导入完成：\(counts.drafts) 份草稿、\(counts.versions) 个版本、\(counts.projects) 个项目、" +
                "\(counts.relations) 条演化关系、\(counts.candidateDecisions) 条裁决、\(counts.pdfSnapshots) 份 PDF 快照。" +
                "线索与索引将自动重建。"
        } catch {
            return "导入失败：\(error.localizedDescription)（未做任何写入，请检查档案后重试）"
        }
    }
}
