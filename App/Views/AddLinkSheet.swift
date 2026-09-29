import SwiftUI
import DraftZeroCore

/// 添加链接（R-002）：网页/GitHub 单文件直接导入；仓库打开文件勾选列表。
struct AddLinkSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var linkText = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        Group {
            if let browse = model.repoBrowse {
                RepoPickerView(browse: browse)
            } else {
                linkEntry
            }
        }
        .archiveSheet()
    }

    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加链接")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            Text("支持普通网页、GitHub 单文件（/blob/）与公开仓库（/ 或 /tree/）。仓库链接会先列出文件，勾选后再导入。")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/article 或 https://github.com/owner/repo", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .font(.archiveBody)
                .focused($linkFocused)
                .onSubmit { Task { await model.openLink(linkText) } }

            if model.linkLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取…").font(.system(size: 12)).foregroundStyle(Color.mutedText)
                }
            }
            if let error = model.linkError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.showAddLinkSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("打开") {
                    Task { await model.openLink(linkText) }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || model.linkLoading)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task { linkFocused = true }
    }
}

/// 仓库文件勾选列表：只导入受支持的文本/PDF；截断时明确标示"列表不完整"。
struct RepoPickerView: View {
    @EnvironmentObject private var model: AppModel
    let browse: RepoBrowse

    private var selectedCount: Int { browse.checked.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(browse.owner)/\(browse.repo)")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Text("分支 \(browse.branch) · 文件 \(browse.entries.count) 个 · 版本标识 \(browse.treeSha.prefix(7))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if browse.truncated {
                Label("列表不完整：仓库过大，GitHub 接口截断了返回结果，可能有文件未列出。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider().overlay(Color.rule)

            List(browse.entries) { entry in
                HStack {
                    if entry.isSupported && !entry.isTooLarge {
                        Toggle("", isOn: Binding(
                            get: { browse.checked.contains(entry.path) },
                            set: { on in toggle(entry.path, on) }))
                            .checkboxStyle()
                            .labelsHidden()
                    } else {
                        Image(systemName: "circle.slash")
                            .foregroundStyle(Color.mutedText)
                            .help(entry.isTooLarge ? "文件过大（超过 2 MB 文本限制）" : "不支持的文件类型")
                    }
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(Color.mutedText)
                    Text(entry.path)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.archiveText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.sizeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                }
                .padding(.vertical, 1)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider().overlay(Color.rule)
            HStack {
                Text("已选 \(selectedCount) 项 · 只会导入勾选的文件")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Button("返回") { model.repoBrowse = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入所选") {
                    Task { await model.importCheckedRepoFiles() }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }

    private func toggle(_ path: String, _ on: Bool) {
        guard var updated = model.repoBrowse else { return }
        if on {
            updated.checked.insert(path)
        } else {
            updated.checked.remove(path)
        }
        model.repoBrowse = updated
    }

    private func icon(for entry: RepoEntry) -> String {
        switch (entry.path as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "md", "markdown": "doc.plaintext"
        case "txt", "text": "doc.plaintext"
        default: "doc"
        }
    }
}

extension Toggle {
    /// 简洁勾选框样式（macOS 默认 toggle 是开关）。
    @ViewBuilder
    func checkboxStyle() -> some View {
        self.toggleStyle(.checkbox)
    }
}
