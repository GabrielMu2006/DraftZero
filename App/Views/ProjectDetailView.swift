import SwiftUI
import DraftZeroCore

/// 项目档案（UI-06 / R-005/R-007/R-008）：上方固定名称、状态菜单、主题标签；
/// 中部「成员 / 演化」切换。演化用时间顺序展示已保存的版本与拆分/合并/衍生/
/// 手动关联/重新解释，图形与可操作文字事件列表表达同一事实；
/// 未确认的候选关系不进入演化视图。图形用普通 SwiftUI 形状绘制（不复用 Canvas）。
struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let width: CGFloat

    private typealias Section = ProjectSection

    @State private var showAddMembers = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var relationRows: [EvolutionRow] = []
    @State private var versionEvents: [VersionEvent] = []
    @State private var selectedEventID: String?
    @State private var typeFilter: RelationType?

    struct EvolutionRow: Identifiable {
        let id: UUID
        let fromId: UUID
        let toId: UUID
        let fromTitle: String?
        let toTitle: String?
        let type: RelationType
        let note: String?
        let date: Date
    }

    struct VersionEvent: Identifiable {
        var id: String { draftId.uuidString + "-v" + versionId.uuidString }
        let draftId: UUID
        let versionId: UUID
        let draftTitle: String
        let origin: VersionOrigin
        let date: Date
        let index: Int
    }

    /// 统一事件（演化列表按时间倒序混合版本与关系）。
    private enum EvolutionEvent: Identifiable {
        case relation(EvolutionRow)
        case version(VersionEvent)

        var id: String {
            switch self {
            case .relation(let row): "r-" + row.id.uuidString
            case .version(let v): v.id
            }
        }

        var date: Date {
            switch self {
            case .relation(let row): row.date
            case .version(let v): v.date
            }
        }
    }

    private var liveProject: Project {
        model.projects.first { $0.id == project.id } ?? project
    }

    private var members: [Draft] { model.projectMembers[project.id] ?? [] }
    private var tags: [Tag] { model.projectTags[project.id] ?? [] }

    /// 成员按导入时间升序（起点在最左）。
    private var orderedMembers: [Draft] {
        members.sorted { $0.importedAt < $1.importedAt }
    }

    private var filteredEvents: [EvolutionEvent] {
        let relations = relationRows
            .filter { typeFilter == nil || $0.type == typeFilter }
            .map { EvolutionEvent.relation($0) }
        let versions = typeFilter == nil
            ? versionEvents.map { EvolutionEvent.version($0) } : []
        return (relations + versions).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.rule)
            HStack(spacing: 0) {
                ForEach(ProjectSection.allCases, id: \.self) { candidate in
                    let isActive = model.projectDetailSection == candidate
                    Button {
                        model.projectDetailSection = candidate
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Color.strongButtonText : Color.archiveText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isActive ? Color.strongButtonBackground : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(candidate.rawValue)视图")
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.raised))
            .overlay(Capsule().strokeBorder(Color.rule, lineWidth: 1))
            .frame(width: 260)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            switch model.projectDetailSection {
            case .members: memberList
            case .evolution: evolutionView
            }
        }
        .background(Color.surface)
        .task { await loadEvolution() }
        .onChange(of: model.projectDetailSection) { _, _ in Task { await loadEvolution() } }
        .sheet(isPresented: $showAddMembers) { AddMembersSheet(project: liveProject) }
        .alert("添加主题标签", isPresented: $showAddTagAlert) {
            TextField("标签名（同名不重复）", text: $tagText)
            Button("添加") {
                let name = tagText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await model.addTag(name, toProject: liveProject.id) }
                tagText = ""
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名项目", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("保存") {
                Task { await model.renameProject(liveProject, to: renameText) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除项目「\(liveProject.name)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除项目（草稿保留）", role: .destructive) {
                Task { await model.deleteProject(liveProject) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("成员草稿不会被删除：仍属于其他项目的继续留在那里，其余回到未归组区。")
        }
    }

    // MARK: - 头部（名称 + 状态 + 标签固定在上）

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    model.closeDetailPages()
                } label: {
                    Label("返回项目", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回（Esc）")
                Text("03 / 项目档案")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Menu {
                    Button("重命名…") {
                        renameText = liveProject.name
                        showRename = true
                    }
                    Button("删除项目…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(liveProject.name)
                    .font(.archiveDetailTitle)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                statusMenu
                Spacer(minLength: 8)
            }
            tagBar
            Text("\(members.count) 份草稿 · \(versionEvents.count) 个文本版本 · \(relationRows.count) 条关系记录")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(ProjectStatus.allCases, id: \.self) { status in
                Button(status.displayName) {
                    Task { await model.setProjectStatus(liveProject, status: status) }
                }
            }
        } label: {
            ArchiveStatusChip(
                text: liveProject.status.displayName,
                color: liveProject.status == .archived ? .mutedText : .confirmed,
                systemImage: liveProject.status.symbolName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel("项目状态：\(liveProject.status.displayName)，打开菜单可更改")
    }

    private var tagBar: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.name) { tag in
                HStack(spacing: 4) {
                    Text(tag.name)
                        .font(.system(size: 11, weight: .medium))
                    Button {
                        Task { await model.removeTag(tag.name, fromProject: liveProject.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除标签 \(tag.name)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accent.opacity(0.12)))
                .foregroundStyle(Color.accent)
            }
            Button {
                showAddTagAlert = true
            } label: {
                Label("添加标签", systemImage: "tag")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mutedText)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    @State private var showAddTagAlert = false
    @State private var tagText = ""

    // MARK: - 成员（一稿多项目可见）

    private var memberList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("成员草稿在所有所属项目中是同一份内容与历史。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Button {
                    showAddMembers = true
                } label: {
                    Label("添加成员", systemImage: "plus")
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            if members.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有成员草稿")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.archiveText)
                    Text("从草稿箱详情或线索台的「加入项目」添加。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(members) { draft in
                            HStack(spacing: 10) {
                                Button {
                                    model.open(draft: draft)
                                } label: {
                                    ArchiveDraftRow(
                                        draft: draft,
                                        projectCount: model.projectCounts[draft.id] ?? 0,
                                        projectNames: model.draftProjects[draft.id] ?? [])
                                }
                                .buttonStyle(.plain)
                                Button("移出") {
                                    Task { await model.removeDraft(draft.id, fromProject: liveProject.id) }
                                }
                                .buttonStyle(ArchiveTextButtonStyle())
                                .fixedSize()
                                .padding(.trailing, 12)
                                .accessibilityLabel("把「\(draft.title)」移出项目（草稿保留）")
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 演化（图形 + 事件列表同屏）

    private var evolutionView: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if relationRows.isEmpty && versionEvents.isEmpty {
                        Text("项目成员之间还没有拆分、合并或手动关联；编辑草稿后，自动保存的版本也会出现在这里。")
                            .font(.archiveFootnote)
                            .foregroundStyle(Color.mutedText)
                            .padding(.top, 24)
                    } else {
                        graphCard
                        eventListSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if width >= 1100, let detail = selectedEventDetail {
                Divider().overlay(Color.rule)
                eventDetailPanel(detail)
                    .frame(width: 280)
            }
        }
        .overlay(alignment: .bottom) {
            if width >= 1100, selectedEventDetail != nil { EmptyView() }
        }
    }

    /// 图形卡：节点卡按时间横排，边为曲线（拆分棕 / 合并衍生绿 / 关联紫，虚线）。
    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已确认的演化路径")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Text("图形 / 文字列表表达同一事实")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
            }
            GeometryReader { geo in
                graphContent(size: geo.size)
            }
            .frame(height: 128)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.rule, lineWidth: 1))
            HStack(spacing: 12) {
                legend("拆分", Color.accent)
                legend("合并/衍生", Color.confirmed)
                legend("关联/解释", Color.remote)
                Text("点击节点选中事件；在事件记录中打开草稿")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
            }
            .accessibilityHidden(true)
        }
    }

    /// 图形节点 = 项目成员 + 关系端点（拆分/合并产物），按导入/事件时间排列。
    private var graphNodes: [GraphNode] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for member in orderedMembers {
            if seen.insert(member.id).inserted { ids.append(member.id) }
        }
        for row in relationRows.sorted(by: { $0.date < $1.date }) {
            for id in [row.fromId, row.toId] where !seen.contains(id) {
                seen.insert(id)
                ids.append(id)
            }
        }
        return ids.map { id in
            let draft = model.drafts.first { $0.id == id }
            return GraphNode(
                id: id,
                title: draft?.title,
                detail: draft.map { "\((model.lastEdited[$0.id] ?? $0.importedAt).formatted(date: .omitted, time: .shortened)) · \($0.isEditable ? "应用内文本" : "快照")" },
                date: draft?.importedAt,
                isMember: members.contains { $0.id == id })
        }
    }

    struct GraphNode: Identifiable {
        let id: UUID
        let title: String?
        let detail: String?
        let date: Date?
        let isMember: Bool
    }

    private func graphContent(size: CGSize) -> some View {
        let nodes = graphNodes
        let slot = size.width / CGFloat(max(nodes.count, 1))
        let midY = size.height / 2
        return ZStack {
            ForEach(relationRows) { row in
                if let from = nodeCenter(row.fromId, nodes: nodes, slot: slot, midY: midY),
                   let to = nodeCenter(row.toId, nodes: nodes, slot: slot, midY: midY),
                   from != to {
                    QuadCurveShape(from: from, to: to)
                        .stroke(edgeColor(row.type).opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.5, dash: row.type == .split ? [4, 3] : []))
                }
            }
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                evolutionNode(
                    node: node,
                    x: slot * (CGFloat(index) + 0.5), y: midY,
                    nodeWidth: min(max(slot - 10, 92), 150))
            }
        }
    }

    private func evolutionNode(node: GraphNode, x: CGFloat, y: CGFloat, nodeWidth: CGFloat) -> some View {
        let isSelected = selectedEventID == "n-\(node.id.uuidString)"
        let title = node.title ?? "来源已删除"
        let heading = node.isMember
            ? "起点 · \(node.date?.formatted(date: .numeric, time: .omitted) ?? "")"
            : (node.title == nil ? "已删除" : "衍生 · \(node.date?.formatted(date: .numeric, time: .omitted) ?? "")")
        return Button {
            selectedEventID = "n-\(node.id.uuidString)"
        } label: {
            VStack(spacing: 2) {
                Text(heading)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mutedText)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(node.title == nil ? Color.accent : Color.archiveText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let detail = node.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: nodeWidth)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.selected : Color.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accent : Color.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .position(x: x, y: y)
        .accessibilityLabel("演化节点：\(title)\(node.isMember ? "，项目成员" : "，关系产物")")
    }

    private func nodeCenter(_ id: UUID, nodes: [GraphNode], slot: CGFloat, midY: CGFloat) -> CGPoint? {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nil }
        return CGPoint(x: slot * (CGFloat(index) + 0.5), y: midY)
    }

    private func edgeColor(_ type: RelationType) -> Color {
        switch type {
        case .split: Color.accent
        case .merge, .derived: Color.confirmed
        case .reinterpret, .manualLink: Color.remote
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10)).foregroundStyle(Color.mutedText)
        }
    }

    /// 可操作文字事件列表（VoiceOver 与键盘的完整替代；图形隐藏时仍可追溯）。
    private var eventListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("事件记录")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Spacer()
                Menu {
                    Button("全部类型") { typeFilter = nil }
                    ForEach(RelationType.allCases, id: \.self) { type in
                        Button(type.displayName) { typeFilter = type }
                    }
                } label: {
                    Label(typeFilter.map { $0.displayName } ?? "按类型筛选", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
            }
            ForEach(filteredEvents, id: \.id) { event in
                eventRow(event)
                Divider().overlay(Color.rule.opacity(0.6))
            }
        }
    }

    private func eventRow(_ event: EvolutionEvent) -> some View {
        let isSelected = selectedEventID == event.id
        return Button {
            selectedEventID = event.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.date.formatted(.dateTime.month().day()))
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Color.mutedText)
                    .frame(width: 46, alignment: .leading)
                switch event {
                case .relation(let row):
                    Text(row.fromTitle ?? "来源已删除")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(row.fromTitle == nil ? Color.accent : Color.archiveText)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedText)
                    ArchiveStatusChip(text: row.type.displayName, color: edgeColor(row.type), outlined: true)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedText)
                    Text(row.toTitle ?? "（已删除）")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(row.toTitle == nil ? Color.accent : Color.archiveText)
                        .lineLimit(1)
                    if let note = row.note, !note.isEmpty {
                        Text("说明：\(note)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedText)
                            .lineLimit(1)
                    }
                case .version(let v):
                    Text(v.draftTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.archiveText)
                        .lineLimit(1)
                    ArchiveStatusChip(text: "版本 v\(v.index) · \(v.origin.displayName)", color: .mutedText)
                    Spacer()
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accent : Color.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(eventAccessibilityLabel(event))
    }

    private func eventAccessibilityLabel(_ event: EvolutionEvent) -> String {
        switch event {
        case .relation(let row):
            let from = row.fromTitle ?? "来源已删除"
            let to = row.toTitle ?? "已删除"
            return "\(row.type.displayName)关系：\(from) 到 \(to)，\(row.date.formatted(date: .abbreviated, time: .shortened))\(row.note.map { "，说明：\($0)" } ?? "")"
        case .version(let v):
            return "版本：\(v.draftTitle) 第 \(v.index) 个版本，\(v.origin.displayName)，\(v.date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    /// 选中事件的关系档案（右侧面板或下方，视宽度）。
    @ViewBuilder
    private func eventDetailPanel(_ detail: EventDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("关系档案")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mutedText)
                switch detail {
                case .relation(let row):
                    Text(summarySentence(row))
                        .font(.archiveSection)
                        .fontDesign(.serif)
                        .foregroundStyle(Color.archiveText)
                    detailField("来源", row.fromTitle ?? "来源已删除")
                    detailField("关系类型", row.type.displayName)
                    detailField("日期", row.date.formatted(date: .abbreviated, time: .shortened))
                    detailField("说明", row.note?.isEmpty == false ? row.note! : "（未填写）")
                    if let fromTitle = row.fromTitle {
                        Button("打开来源草稿 →") {
                            if let draft = model.drafts.first(where: { $0.id == row.fromId }) {
                                model.open(draft: draft)
                            }
                        }
                        .buttonStyle(ArchiveTextButtonStyle())
                    }
                    if let toTitle = row.toTitle {
                        Button("打开目标草稿 →") {
                            if let draft = model.drafts.first(where: { $0.id == row.toId }) {
                                model.open(draft: draft)
                            }
                        }
                        .buttonStyle(ArchiveTextButtonStyle())
                    }
                case .version(let v):
                    Text("一次\(v.origin == .autoSave ? "自动保存" : v.origin.displayName)，记录了当时的正文。")
                        .font(.archiveSection)
                        .fontDesign(.serif)
                        .foregroundStyle(Color.archiveText)
                    detailField("草稿", v.draftTitle)
                    detailField("版本来源", v.origin.displayName)
                    detailField("时间", v.date.formatted(date: .abbreviated, time: .shortened))
                    Button("打开草稿与版本 →") {
                        if let draft = model.drafts.first(where: { $0.id == v.draftId }) {
                            model.open(draft: draft)
                        }
                    }
                    .buttonStyle(ArchiveTextButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.raised)
    }

    private enum EventDetail {
        case relation(EvolutionRow)
        case version(VersionEvent)
    }

    private var selectedEventDetail: EventDetail? {
        guard let selectedEventID else { return nil }
        if selectedEventID.hasPrefix("n-") {
            let idString = String(selectedEventID.dropFirst(2))
            if let id = UUID(uuidString: idString),
               let draft = model.drafts.first(where: { $0.id == id }),
               let version = versionEvents.last(where: { $0.draftId == draft.id }) {
                return .version(version)
            }
            return nil
        }
        for event in filteredEvents {
            if event.id == selectedEventID {
                switch event {
                case .relation(let row): return .relation(row)
                case .version(let v): return .version(v)
                }
            }
        }
        return nil
    }

    private func summarySentence(_ row: EvolutionRow) -> String {
        switch row.type {
        case .split: return "一次拆分，留下了新的草稿。"
        case .merge: return "一次合并，保留了两份来源。"
        case .derived: return "一次衍生，源自已有草稿。"
        case .reinterpret: return "一次重新解释，说明了新的关系。"
        case .manualLink: return "一次手动关联，由你确认。"
        }
    }

    private func detailField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mutedText)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Color.archiveText)
                .textSelection(.enabled)
            Divider().overlay(Color.rule.opacity(0.5))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 数据

    private func loadEvolution() async {
        var rows: [EvolutionRow] = []
        var versions: [VersionEvent] = []
        var seenRelations = Set<UUID>()
        for member in members {
            await model.loadRelations(draftId: member.id)
            for relation in model.draftRelations[member.id] ?? [] {
                // 成员任一端的关系都算项目演化；同一关系只记录一次
                guard seenRelations.insert(relation.id).inserted else { continue }
                rows.append(EvolutionRow(
                    id: relation.id,
                    fromId: relation.sourceDraftId,
                    toId: relation.targetDraftId,
                    fromTitle: model.draftTitle(id: relation.sourceDraftId),
                    toTitle: model.draftTitle(id: relation.targetDraftId),
                    type: relation.type,
                    note: relation.note,
                    date: relation.createdAt))
            }
            if let database = model.database {
                let all = (try? await database.versions(draftId: member.id)) ?? []
                for (index, version) in all.enumerated() {
                    versions.append(VersionEvent(
                        draftId: member.id,
                        versionId: version.id,
                        draftTitle: member.title,
                        origin: version.origin,
                        date: version.createdAt,
                        index: all.count - index))
                }
            }
        }
        relationRows = rows.sorted { $0.date > $1.date }
        versionEvents = versions.sorted { $0.date > $1.date }
    }
}

/// 把未加入项目的草稿勾选加入（R-005）。
struct AddMembersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var selected: Set<UUID> = []

    private var candidates: [Draft] {
        let memberIds = Set(model.projectMembers[project.id]?.map(\.id) ?? [])
        return model.drafts.filter { !memberIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("把草稿加入「\(project.name)」")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
                .padding(14)
            Divider().overlay(Color.rule)
            List(candidates) { draft in
                Button {
                    if selected.contains(draft.id) {
                        selected.remove(draft.id)
                    } else {
                        selected.insert(draft.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.archiveText)
                            Text(draft.sourceType.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mutedText)
                        }
                        Spacer()
                        if selected.contains(draft.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.confirmed)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider().overlay(Color.rule)
            HStack {
                Text("已选 \(selected.count) 份")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("加入") {
                    Task {
                        for id in selected {
                            await model.addDraft(id, toProject: project.id)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .archiveSheet()
    }
}
