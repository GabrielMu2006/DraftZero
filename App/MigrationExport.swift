import SwiftUI
import AppKit
import DraftZeroCore

/// V0.2.0 一次性 Mac→Windows 迁移导出（计划 §3）。
/// 设置页入口：输出版本化 .dzarchive（ZIP 容器）；导出为**复制**，源工作区不变；
/// 档案未加密，含草稿正文与 PDF，保存位置由用户选择，应用不自行上传。
enum MigrationExport {

    static let appVersion = "0.2.0"

    /// 执行导出；返回可读的结果说明（成功含条目计数，失败含原因）。
    @MainActor
    static func runExport(database: AppDatabase?, snapshotsDirectory: URL, to url: URL) async -> String {
        guard let database else {
            return "工作区尚未就绪，请稍后重试"
        }
        do {
            try await DzArchiveExporter.export(
                database: database, snapshotsDirectory: snapshotsDirectory,
                to: url, appVersion: appVersion)
            return "已导出至 \(url.lastPathComponent)。档案未加密，含草稿正文与 PDF，请妥善保管。"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }
}
