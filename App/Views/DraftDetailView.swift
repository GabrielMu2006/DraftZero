import SwiftUI
import DraftZeroCore

/// 草稿阅读与编辑（UI-07 / R-003/R-006/R-007/R-011）：
/// 同一套柔和纸面；正文宽度上限 720；编辑状态显示 已保存/正在保存/保存失败；
/// 版本与来路检查栏在宽窗口并列、默认宽度按需打开；快照只读并有「创建可编辑副本」；
/// 拆分/合并/关系说明为次级操作。
struct DraftDetailView: View {
    @EnvironmentObject private var model: AppModel
    let draft: Draft
    let width: CGFloat

    @State private var isEditing = false
    @State private var editText = ""
    @State private var versions: [DraftVersion] = []
    @State private var showDeleteConfirm = false
    @State private var deleteImpact = ""
    @State private var compareSelection: CompareSelection?
    @State private var noteEditing: EvolutionRelation?
    @State private var showInspector = false

    struct CompareSelection: Identifiable {
        let id = UUID()
        let old: DraftVersion
        let new: DraftVersion
    }

    /// ≥1280 时检查栏常驻并列；更窄按需打开覆盖面板。
    private var inspectorPinned: Bool { width >= 1280 }
    private var inspectorVisible: Bool { inspectorPinned || showInspector }

    /// 阅读模式下的段落切分（含原文偏移，供拆分定位）。
    private var paragraphs: [(text: String, offset: Int)] {
        guard let content = draft.content, !content.isEmpty else { return [] }
        var result: [(String, Int)] = []
        var cursor = content.startIndex
        while let separator = content.range(of: "\n\n", range: cursor..<content.endIndex) {
            if separator.lowerBound > cursor {
                result.append((String(content[cursor..<separator.lowerBound]),
                               content.distance(from: content.startIndex, to: cursor)))
            }
            cursor = separator.upperBound
        }
        if cursor < content.endIndex {
            result.append((String(content[cursor...]),
                           content.distance(from: content.startIndex, to: cursor)))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if inspectorVisible {
                Divider().overlay(Color.rule)
                ArchiveInspector(title: "版本与来路", onClose: inspectorPinned ? nil : { showInspector = false }) {
                    inspectorContent
                }
                .frame(width: 300)
            }
        }
        .background(Color.surface)
        .task(id: draft.id) {
            editText = draft.content ?? ""
            isEditing = false
            showInspector = false
            model.editSaveState = .idle
            await loadVersions()
            await model.loadRelations(draftId: draft.id)
        }
        .onChange(of: draft.id) { oldID, _ in
            Task { await model.flushVersion(draftId: oldID) }
        }
        .sheet(item: $compareSelection) { selection in
            VersionCompareSheet(old: selection.old, new: selection.new)
        }
        .sheet(item: $noteEditing) { relation in
            RelationNoteSheet(relation: relation, draftId: draft.id)
        }
        .confirmationDialog("删除「\(draft.title)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除草稿", role: .destructive) {
                Task { await model.deleteDraft(draft) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteImpact)
        }
    }

    // MARK: - 主栏

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            if !draft.hasExtractableText {
                noTextNotice
            }
            Divider().overlay(Color.rule)
            contentArea
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    Task { await model.flushVersion(draftId: draft.id) }
                    model.closeDetailPages()
                } label: {
                    Label("返回草稿箱", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回（Esc）")
                Text("01 / 草稿箱")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                if !inspectorPinned {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("版本与来路", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(ArchiveSecondaryButtonStyle())
                    .help("查看版本历史与来路")
                }
                if isEditing {
                    Button("完成") {
                        Task {
                            await model.flushVersion(draftId: draft.id)
                            isEditing = false
                            await loadVersions()
                        }
                    }
                    .buttonStyle(ArchiveStrongButtonStyle())
                } else if draft.isEditable {
                    Button("编辑") { isEditing = true }
                        .buttonStyle(ArchiveStrongButtonStyle())
                } else if draft.hasExtractableText {
                    Button("创建可编辑副本") {
                        Task { await model.createEditableCopy(from: draft) }
                    }
                    .buttonStyle(ArchiveStrongButtonStyle())
                }
                Menu {
                    Button("删除草稿…", role: .destructive) {
                        Task {
                            deleteImpact = await model.deletionImpact(for: draft)
                            showDeleteConfirm = true
                        }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(draft.title)
                    .font(.archiveDetailTitle)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ArchiveStatusChip(
                    text: draft.isEditable ? "可编辑" : "只读快照",
                    color: draft.isEditable ? .confirmed : .mutedText)
            }
            HStack(spacing: 10) {
                Label(draft.sourceType.displayName, systemImage: draft.sourceType.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                if let label = draft.sourceLabel {
                    Text("来源：\(label)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let sha = draft.sourceVersionSha {
                    Text("版本标识 \(sha.prefix(7))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedText)
                }
                Text("导入于 \(draft.importedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var noTextNotice: some View {
        Label("扫描版 PDF：无可用于关联的文字（保留快照供阅读）", systemImage: "exclamationmark.triangle")
            .font(.archiveFootnote)
            .foregroundStyle(Color.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.accent.opacity(0.08))
    }

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            Group {
                if isEditing {
                    VStack(alignment: .leading, spacing: 0) {
                        saveStateLine
                        TextEditor(text: $editText)
                            .font(.archiveBody)
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 380)
                            .padding(.top, 6)
                            // R-012/VoiceOver：编辑区无可读名称时朗读只有"编辑文本"
                            .accessibilityLabel("正文编辑区")
                            .onChange(of: editText) { _, newValue in
                                Task { await model.saveEdit(draftId: draft.id, text: newValue) }
                            }
                    }
                    .padding(24)
                } else if let content = draft.content, !content.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph.text)
                                .font(.archiveBody)
                                .foregroundStyle(Color.archiveText)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if draft.isEditable {
                                        Button("把这一段拆为新草稿") {
                                            Task { await model.splitDraft(draft, piece: paragraph.text, offset: paragraph.offset) }
                                        }
                                    }
                                }
                        }
                    }
                    .padding(24)
                } else {
                    Text(draft.hasExtractableText ? "（空草稿）" : "（无可用于关联的文字）")
                        .font(.archiveBody)
                        .foregroundStyle(Color.mutedText)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    /// 编辑保存状态（不以"60 秒后留版本"代替保存反馈）。
    @ViewBuilder
    private var saveStateLine: some View {
        HStack(spacing: 6) {
            switch model.editSaveState {
            case .idle:
                EmptyView()
            case .saving:
                ProgressView().controlSize(.mini)
                Text("正在保存…").font(.system(size: 11)).foregroundStyle(Color.mutedText)
            case .saved:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.confirmed)
                Text("已保存 · 停止输入 60 秒后自动留版本")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedText)
            case .failed(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.danger)
                Text("保存失败：\(message)")
                    .font(.system(size: 11)).foregroundStyle(Color.danger)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        ArchiveActionBar {
            if isEditing {
                saveStateLine
            } else {
                // 次级操作：拆分说明与关系说明入口不占正文最强位置
                if !(model.draftRelations[draft.id] ?? []).isEmpty {
                    Text("来路：\(relationSummary)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(draft.isEditable ? "应用内编辑不写回原文件" : "外部快照只读；原文件与远端内容不受影响")
                .font(.system(size: 11))
                .foregroundStyle(Color.mutedText)
        }
    }

    private var relationSummary: String {
        let relations = model.draftRelations[draft.id] ?? []
        let parts = relations.prefix(2).map { relation -> String in
            let isIncoming = relation.targetDraftId == draft.id
            let counterpart = model.draftTitle(id: isIncoming ? relation.sourceDraftId : relation.targetDraftId)
            let verb: String = switch relation.type {
            case .split: isIncoming ? "拆分自" : "被拆分为"
            case .merge: isIncoming ? "合并自" : "被合并进"
            case .derived: isIncoming ? "源自" : "衍生出"
            case .reinterpret: "重新解释"
            case .manualLink: "手动关联"
            }
            let name = counterpart ?? (isIncoming ? "来源已删除" : "已删除")
            return "\(verb)「\(name)」"
        }
        let joined = parts.joined(separator: "、")
        return relations.count > 2 ? joined + " 等 \(relations.count) 条" : joined
    }

    // MARK: - 检查栏：版本历史 + 来路

    @ViewBuilder
    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            versionSection
            Divider().overlay(Color.rule)
            originSection
            Divider().overlay(Color.rule)
            deleteSection
        }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("版本历史（\(versions.count)）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.archiveText)
            if versions.isEmpty {
                Text("还没有版本；编辑后自动保存会留下版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
            }
            ForEach(Array(versions.prefix(8).enumerated()), id: \.element.id) { index, version in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.archiveText)
                        Spacer()
                        ArchiveStatusChip(text: version.origin.displayName, color: .confirmed)
                    }
                    HStack {
                        Spacer()
                        // 与相邻的上一版本对比（R-006"比较两个版本"）。
                        Button("对比") {
                            compareSelection = CompareSelection(
                                old: versions[index + 1], new: version)
                        }
                        .buttonStyle(ArchiveTextButtonStyle())
                        .disabled(index + 1 >= versions.count)
                        Button("恢复此版本") {
                            Task {
                                await model.restore(version: version)
                                await loadVersions()
                            }
                        }
                        .buttonStyle(ArchiveTextButtonStyle())
                        .disabled(version.id == versions.first?.id)
                    }
                }
                .padding(.vertical, 2)
            }
            if versions.count > 8 {
                Text("其余 \(versions.count - 8) 个更早版本可在项目演化的事件记录中查看")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
            }
        }
    }

    /// 来路（R-007）：拆分/合并/衍生/重新解释关系；来源被删除时明确显示。
    private var originSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("来路")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.archiveText)
            let relations = model.draftRelations[draft.id] ?? []
            if relations.isEmpty {
                Text("没有拆分、合并或衍生记录。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
            }
            ForEach(relations) { relation in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.confirmed)
                    Text(originText(for: relation))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.archiveText)
                    Spacer()
                    Button("说明…") {
                        noteEditing = relation
                    }
                    .buttonStyle(ArchiveTextButtonStyle())
                }
            }
        }
    }

    private func originText(for relation: EvolutionRelation) -> String {
        let isIncoming = relation.targetDraftId == draft.id
        let counterpartId = isIncoming ? relation.sourceDraftId : relation.targetDraftId
        let counterpart = model.draftTitle(id: counterpartId)
        let verb: String = switch relation.type {
        case .split: isIncoming ? "拆分自" : "被拆分为"
        case .merge: isIncoming ? "合并自" : "被合并进"
        case .derived: isIncoming ? "源自" : "衍生出"
        case .reinterpret: "重新解释"
        case .manualLink: "手动关联"
        }
        if isIncoming {
            if let counterpart {
                return "\(verb)「\(counterpart)」"
            }
            if relation.type == .split || relation.type == .merge || relation.type == .derived {
                return "\(verb)来源已删除的草稿"
            }
            return "\(verb)（对方草稿已删除）"
        }
        return counterpart.map { "\(verb)「\($0)」" } ?? "\(verb)（对方草稿已删除）"
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("归属")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.archiveText)
            let owning = model.draftProjects[draft.id] ?? []
            Text(owning.isEmpty ? "未归组（可从线索台或项目页加入项目）"
                 : "属于 \(owning.joined(separator: "、"))")
                .font(.system(size: 11))
                .foregroundStyle(Color.mutedText)
            Button("删除草稿…", role: .destructive) {
                Task {
                    deleteImpact = await model.deletionImpact(for: draft)
                    showDeleteConfirm = true
                }
            }
            .buttonStyle(ArchiveTextButtonStyle())
            .foregroundStyle(Color.danger)
        }
    }

    private func loadVersions() async {
        guard let database = model.database else { return }
        versions = (try? await database.versions(draftId: draft.id)) ?? []
    }
}
