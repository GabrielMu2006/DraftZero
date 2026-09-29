import SwiftUI

/// 全页新稿（UI-04 / R-001）：主工作区中的专注写作页，标题可稍后补；
/// 光标默认在正文；标题正文都空时保存不可用；返回未保存内容给出选择；
/// 保存失败保留输入并显示具体错误。所有入口（顶栏、⌘N、深链、空态）都进这一页。
struct NewDraftPage: View {
    @EnvironmentObject private var model: AppModel

    @State private var title = ""
    @State private var content = ""
    @State private var showDiscardConfirm = false
    @State private var isSaving = false

    private var hasInput: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.rule)
            ZStack {
                ArchiveWritingCanvas(title: $title, content: $content)
                if let error = model.newDraftError {
                    VStack {
                        Spacer()
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.archiveFootnote)
                            .foregroundStyle(Color.danger)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .archiveCard()
                            .padding(.bottom, 16)
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("newDraftError")
                }
            }
            footer
        }
        .background(Color.surface)
        .confirmationDialog(
            "返回后未保存的内容会丢失", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("继续编辑", role: .cancel) {}
            Button("丢弃未保存内容", role: .destructive) {
                title = ""
                content = ""
                model.newDraftError = nil
                model.closeDetailPages()
            }
        } message: {
            Text("也可以先保存到草稿箱——不完整也可以保存。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if hasInput {
                    showDiscardConfirm = true
                } else {
                    model.newDraftError = nil
                    model.closeDetailPages()
                }
            } label: {
                Label("返回草稿箱", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("返回（Esc）")

            Text("新草稿")
                .font(.system(size: 15, weight: .semibold))
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            Spacer()
            Text("暂存于草稿箱 · 可稍后归类")
                .font(.archiveFootnote)
                .foregroundStyle(Color.mutedText)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        ArchiveActionBar {
            Spacer()
            if let error = model.newDraftError {
                Text("已保留你写的内容")
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.danger)
            }
            Button("保存到草稿箱") {
                guard hasInput, !isSaving else { return }
                isSaving = true
                Task {
                    let ok = await model.createDraft(title: title, content: content)
                    isSaving = false
                    if ok {
                        title = ""
                        content = ""
                        model.closeDetailPages()
                    }
                }
            }
            .buttonStyle(ArchiveStrongButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!hasInput || isSaving)
            .accessibilityHint("标题可以留空；只有正文时用第一句作临时标题")
        }
    }
}
