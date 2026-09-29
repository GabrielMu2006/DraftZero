import SwiftUI

/// 导入批次结果（R-001 逐项报告；R-011/§6 重复项提示后由用户决定）。
struct ImportSessionView: View {
    @EnvironmentObject private var model: AppModel
    let session: ImportSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.isRunning ? "导入中…" : "导入完成")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Spacer()
                if session.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)

            Divider().overlay(Color.rule)

            List(session.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.archiveText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        statusDetail(item)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mutedText)
                    }
                    Spacer()
                    statusBadge(item)
                    if case .duplicate(let existing) = item.status {
                        Button("另存新快照") {
                            Task { await model.importAnyway(itemID: item.id) }
                        }
                        .buttonStyle(ArchiveTextButtonStyle())
                        .help("已有「\(existing)」，仍要单独保存一份新快照")
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider().overlay(Color.rule)
            HStack {
                Text("导入会复制内容进应用，原文件不会改动。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Button("完成") { model.importSession = nil }
                    .buttonStyle(ArchiveStrongButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isRunning && session.items.allSatisfy { $0.status == .pending })
            }
            .padding(12)
        }
        .frame(width: 520, height: 400)
        .archiveSheet()
    }

    @ViewBuilder
    private func statusDetail(_ item: ImportItem) -> some View {
        switch item.status {
        case .pending: Text("等待处理")
        case .running: Text("正在读取…")
        case .success: Text("已导入")
        case .duplicate(let existing): Text("与已有草稿「\(existing)」来源或内容相同")
        case .failed(let reason): Text(reason).foregroundStyle(Color.danger)
        }
    }

    @ViewBuilder
    private func statusBadge(_ item: ImportItem) -> some View {
        switch item.status {
        case .pending, .running:
            EmptyView()
        case .success:
            ArchiveStatusChip(text: "成功", color: .confirmed, systemImage: "checkmark.circle.fill")
        case .duplicate:
            ArchiveStatusChip(text: "重复", color: .accent, systemImage: "exclamationmark.square", outlined: true)
        case .failed:
            ArchiveStatusChip(text: "失败", color: .danger, systemImage: "xmark.circle.fill", outlined: true)
        }
    }
}
