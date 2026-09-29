import SwiftUI
import UniformTypeIdentifiers
import DraftZeroCore

/// 草稿箱（UI-03）：收纳杂物 + 找回下一步。顶部统计与筛选，
/// 行式档案卡列表，宽窗口右侧「继续推进」辅助栏，页面各处可拖入文件。
struct DraftBoxView: View {
    @EnvironmentObject private var model: AppModel
    let width: CGFloat

    @State private var isTargeted = false
    @State private var showMergeSheet = false

    private var filteredDrafts: [Draft] {
        var list = model.drafts
        switch model.draftBoxFilter {
        case .all:
            break
        case .ungrouped:
            list = list.filter { (model.projectCounts[$0.id] ?? 0) == 0 }
        case .recentlyEdited:
            list = list.sorted {
                lastActivity($0) > lastActivity($1)
            }
            return list
        case .snapshots:
            list = list.filter { !$0.sourceType.isEditableByDefault || !$0.isEditable }
        }
        return list
    }

    /// 最近活动：最近一次版本时间，无版本回退导入时间（视图状态，不改数据）。
    private func lastActivity(_ draft: Draft) -> Date {
        max(model.lastEdited[draft.id] ?? draft.importedAt, draft.importedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider().overlay(Color.rule)
            if model.drafts.isEmpty {
                emptyState
            } else {
                contentArea
            }
        }
        .background(Color.surface)
        .sheet(isPresented: $showMergeSheet) {
            MergeSheet()
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(at: urls) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .overlay {
            if isTargeted {
                dropTargetOverlay
            }
        }
    }

    private var header: some View {
        ArchivePageHeader(
            index: "01",
            title: "草稿箱",
            subtitle: subtitleText) {
            Menu {
                Button("导入本地文件…") { model.pickAndImport() }
                    .keyboardShortcut("o")
                Button("添加链接…") { model.showAddLinkSheet = true }
                    .keyboardShortcut("l")
                Button("合并草稿…") { showMergeSheet = true }
            } label: {
                Label("添加 / 更多", systemImage: "plus.viewfinder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
    }

    private var subtitleText: String {
        var parts: [String] = ["\(model.drafts.count) 份素材"]
        if model.ungroupedCount > 0 {
            parts.append("\(model.ungroupedCount) 份尚未归组")
        }
        if model.pendingClueCount > 0 {
            parts.append("\(model.pendingClueCount) 条归类建议待确认")
        }
        return parts.joined(separator: " · ")
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            ArchiveFilterChips(
                options: DraftBoxFilter.allCases,
                label: { $0.rawValue },
                count: { option in
                    switch option {
                    case .all: model.drafts.isEmpty ? nil : model.drafts.count
                    case .ungrouped: model.ungroupedCount > 0 ? model.ungroupedCount : nil
                    case .recentlyEdited, .snapshots: nil
                    }
                },
                selection: $model.draftBoxFilter)
            Spacer()
            if model.pendingClueCount > 0 {
                Button {
                    model.closeDetailPages()
                    model.sidebarSelection = .clueDesk
                } label: {
                    Label("去线索台查看依据", systemImage: "sparkles.rectangle.stack")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .help("查看 \(model.pendingClueCount) 条待确认线索的依据")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    /// 宽窗口（≥1080）显示「继续推进」辅助栏。
    private var showsAside: Bool { width >= 1080 }

    private var contentArea: some View {
        HStack(alignment: .top, spacing: 0) {
            draftList
            if showsAside {
                Divider().overlay(Color.rule)
                ContinueAside()
                    .frame(width: 264)
            }
        }
    }

    private var draftList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredDrafts) { draft in
                    Button {
                        model.open(draft: draft)
                    } label: {
                        ArchiveDraftRow(
                            draft: draft,
                            projectCount: model.projectCounts[draft.id] ?? 0,
                            projectNames: model.draftProjects[draft.id] ?? [],
                            trailingHint: hint(for: draft))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(for draft: Draft) -> String? {
        draft.isEditable ? "继续写 →" : "查看 →"
    }

    private var dropTargetOverlay: some View {
        ZStack {
            Color.surface.opacity(0.92).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 14)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(Color.accent)
                .padding(28)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accent)
                Text("松手复制进应用，不修改原文件")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
            }
        }
    }

    private var emptyState: some View {
        ArchiveEmptyState(
            symbolName: "tray.and.arrow.down",
            title: "所有未完成的，都先放在这里。",
            message: "拖入 TXT、Markdown 或 PDF，粘贴网页与 GitHub 链接，或先写一句话、半篇文章、一个待办念头。导入只是复制进应用，原文件不会被动。",
            primaryTitle: "新建草稿",
            primaryAction: { model.openNewDraftPage() },
            secondaryTitle: "导入文件 / 链接",
            secondaryAction: { model.pickAndImport() })
    }
}

/// 「继续推进」辅助栏：TODO 项目、最近项目、待确认线索（不创造草稿级 TODO）。
struct ContinueAside: View {
    @EnvironmentObject private var model: AppModel

    private var todoProjects: [Project] {
        model.projects.filter { $0.status == .todo }.prefix(2).map { $0 }
    }

    private var recentProjects: [Project] {
        model.projects.filter { $0.status != .archived && $0.status != .todo }.prefix(2).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("继续推进")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .padding(.top, 18)

                if todoProjects.isEmpty && recentProjects.isEmpty && model.pendingClueCount == 0 {
                    Text("把项目设为 TODO 后，会在这里等你继续。")
                        .font(.archiveFootnote)
                        .foregroundStyle(Color.mutedText)
                }

                if !todoProjects.isEmpty {
                    asideSection("TODO 项目")
                    ForEach(todoProjects) { project in
                        asideProjectRow(project, detail: "\(model.projectMembers[project.id]?.count ?? 0) 份草稿 · 等你继续")
                    }
                }
                if !recentProjects.isEmpty {
                    asideSection("最近项目")
                    ForEach(recentProjects) { project in
                        asideProjectRow(project, detail: project.status.displayName)
                    }
                }
                if model.pendingClueCount > 0 {
                    asideSection("待确认线索")
                    Button {
                        model.closeDetailPages()
                        model.sidebarSelection = .clueDesk
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(model.pendingClueCount) 条线索可确认归类")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.archiveText)
                            Text("去线索台查看依据 →")
                                .font(.archiveFootnote)
                                .foregroundStyle(Color.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .archiveCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.surface)
    }

    private func asideSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mutedText)
    }

    private func asideProjectRow(_ project: Project, detail: String) -> some View {
        Button {
            model.sidebarSelection = .projects
            model.open(project: project)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 15, weight: .medium))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .archiveCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开项目 \(project.name)，\(detail)")
    }
}
