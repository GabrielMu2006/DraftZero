import SwiftUI
import DraftZeroCore

/// 设置（UI-08 / SPEC §3「设置」位）："本机归类"与"可选 DeepSeek"清晰分开；
/// 显示模型与索引状态、重建索引入口、外发范围说明、Key 状态；默认关闭远程（R-010）。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKeyInput = ""

    var body: some View {
        VStack(spacing: 0) {
            ArchivePageHeader(index: "06", title: "设置", subtitle: "本机优先；远程分析默认关闭")
            Divider().overlay(Color.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    localSection
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
