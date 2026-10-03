import SwiftUI
import DraftZeroCore

/// 设置（UI-08 / SPEC §3「设置」位）："本机归类"与"可选 DeepSeek"清晰分开；
/// 显示模型与索引状态、重建索引入口、外发范围说明、Key 状态；默认关闭远程（R-010）。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKeyInput = ""
    @State private var migrationExporting = false
    @State private var migrationMessage: String?
    @State private var winImportRunning = false
    @State private var winImportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ArchivePageHeader(index: "06", title: "设置", subtitle: "本机优先；远程分析默认关闭")
            Divider().overlay(Color.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    localSection
                    migrationSection
                    winImportSection
                    remoteSection
                }
                .padding(24)
                .frame(maxWidth: 660, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.surface)
        .task { model.refreshRemoteState() }
    }

    // MARK: - 本机归类

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本机归类", systemImage: "cpu")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    switch model.semanticState {
                    case .idle, .indexing:
                        ProgressView().controlSize(.small)
                        Text("索引中…").font(.archiveBody).foregroundStyle(Color.mutedText)
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.confirmed)
                        Text("语义模型正常 · 已索引 \(model.clueReport?.indexedDrafts ?? 0) 份草稿")
                            .font(.archiveBody)
                            .foregroundStyle(Color.archiveText)
                    case .degraded(let message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.accent)
                        Text(message).font(.archiveBody).foregroundStyle(Color.archiveText)
                    }
                    Spacer()
                }
                Text("本机语义模型（multilingual-e5-small，随应用分发）离线运行，模型与索引不出本机。索引损坏时可重建，不影响已确认的项目归属。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重建索引") {
                    Task { await model.rebuildSemanticIndex() }
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
                .disabled(model.semanticState == .indexing)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .archiveCard()
        }
    }

    // MARK: - 迁移导出（V0.2.0 计划 §3：一次性 Mac→Windows）

    private var migrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("迁移到 Windows", systemImage: "arrow.right.square")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            VStack(alignment: .leading, spacing: 10) {
                Text("导出一个 .dzarchive 工作区档案，供 Windows 版**首次启动时一次性导入**。导出是复制：本 Mac 工作区保持不变，之后两边不会自动同步。档案未加密，包含全部草稿正文、PDF 快照、项目、版本与你的归类裁决；**不包含** DeepSeek Key（需在 Windows 重新填写）与可重建的索引。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(migrationExporting ? "正在导出…" : "导出至 Windows…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "DraftZero-工作区.dzarchive"
                    panel.message = "选择档案保存位置（含草稿正文与 PDF，请自行选择安全位置）"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    migrationExporting = true
                    migrationMessage = nil
                    Task {
                        let message = await MigrationExport.runExport(
                            database: model.database,
                            snapshotsDirectory: AppDatabase.defaultSnapshotsURL(),
                            to: url)
                        await MainActor.run {
                            migrationExporting = false
                            migrationMessage = message
                        }
                    }
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
                .disabled(migrationExporting)
                if let message = migrationMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(message.hasPrefix("导出失败") ? Color.danger : Color.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .archiveCard()
        }
    }

    // MARK: - 从 Windows 导入（D-002 双向迁移）

    private var winImportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("从 Windows 导入工作区", systemImage: "arrow.down.square")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            VStack(alignment: .leading, spacing: 10) {
                Text("导入 Windows 版「设置 → 导出当前工作区」生成的 .dzarchive 档案。**仅支持导入到空工作区**：请先确认本 Mac 工作区为空（或整体备份后清空），失败时零部分写入。导入后本机会自动重建语义索引；DeepSeek Key 需重新填写。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(winImportRunning ? "正在导入…" : "从 Windows 档案导入…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    panel.allowedFileTypes = ["dzarchive"]
                    panel.message = "选择 Windows 导出的 .dzarchive 档案"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    winImportRunning = true
                    winImportMessage = nil
                    Task {
                        let message = await MigrationImport.runImport(
                            database: model.database,
                            snapshotsDirectory: AppDatabase.defaultSnapshotsURL(),
                            archiveURL: url)
                        await MainActor.run {
                            winImportRunning = false
                            winImportMessage = message
                        }
                    }
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
                .disabled(winImportRunning || model.database == nil)
                if let message = winImportMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(message.hasPrefix("导入失败") ? Color.danger : Color.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .archiveCard()
        }
    }

    // MARK: - DeepSeek（R-010）

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("DeepSeek 分析（可选）", systemImage: "cloud")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    // 档案风格开关按钮：替代 NSSwitch（本机 Metal 遥测崩溃规避，见验收记录）
                    Button {
                        if model.remoteEnabled {
                            model.disableRemoteAnalysis()
                        } else {
                            Task { await model.enableRemoteAnalysis(apiKey: apiKeyInput) }
                        }
                    } label: {
                        Text(model.remoteEnabled ? "远程分析：已开启（点击关闭）" : "远程分析：默认关闭（点击开启）")
                    }
                    .buttonStyle(ArchiveStrongButtonStyle())
                    .accessibilityLabel("启用远程分析")
                    .accessibilityValue(model.remoteEnabled ? "已开启" : "已关闭")
                    Spacer()
                    ArchiveStatusChip(
                        text: model.remoteEnabled ? "已开启" : "默认关闭",
                        color: model.remoteEnabled ? .remote : .mutedText,
                        systemImage: model.remoteEnabled ? "cloud.fill" : "cloud")
                    if model.remoteAnalyzing {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("启用后，新加入草稿的可读取文本（标题与正文节选，不含文件路径、不上传原始文件）会发送至 DeepSeek 分析。可能产生由你的 DeepSeek 账户支付的费用。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    SecureField(placeholder, text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        // R-012/VoiceOver：无可见标签的字段必须有可读名称
                        .accessibilityLabel("DeepSeek API Key")
                        .accessibilityHint(placeholder)
                    if model.remoteHasKey {
                        Button("移除 Key", role: .destructive) {
                            apiKeyInput = ""
                            model.removeRemoteKey()
                        }
                        .foregroundStyle(Color.danger)
                    } else {
                        Button("保存 Key") {
                            Task { await model.enableRemoteAnalysis(apiKey: apiKeyInput) }
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text("Key 保存在本机钥匙串，不写入草稿、导出内容或普通日志。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)

                if let status = model.remoteStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(model.remoteAnalyzing ? Color.mutedText : Color.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Color.rule)

                Text("远程建议仅在引用了草稿原文片段时才会展示，始终标注「远程补充 · DeepSeek」，只是建议——不自动确认任何归类。关闭或失败时本机归类照常可用。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("分析现有草稿") {
                    Task { await model.analyzeAllDraftsRemotely() }
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
                .disabled(!model.remoteEnabled || model.remoteAnalyzing)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .archiveCard()
        }
    }

    private var placeholder: String {
        model.remoteHasKey ? "已保存（输入新 Key 可替换）" : "sk-…"
    }
}
