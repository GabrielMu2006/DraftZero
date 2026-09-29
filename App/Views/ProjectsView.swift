import SwiftUI
import DraftZeroCore

/// 想法项目列表（R-005）与状态筛选页（R-008：TODO / 暂时封存）。
/// 项目页提供「全部 / TODO / 暂时封存」入口；空态只有一个新建入口。
struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    let filter: ProjectStatus?

    @State private var showCreate = false

    private var title: String {
        switch filter {
        case .todo: "TODO"
        case .archived: "暂时封存"
        default: "想法项目"
        }
    }

    private var projects: [Project] {
        model.projects.filter { filter == nil || $0.status == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            ArchivePageHeader(
                index: filter == .todo ? "04" : filter == .archived ? "05" : "03",
                title: title,
                subtitle: "\(projects.count) 个项目") {
                Menu {
                    Button("新建项目…") { showCreate = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Label("添加 / 更多", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
            }
            if filter == nil {
                statusChips
            }
            Divider().overlay(Color.rule)
            if projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .background(Color.surface)
        .sheet(isPresented: $showCreate) { NewProjectSheet() }
    }

    /// 状态入口（与索引页共用语义；切换即换页）。
    private var statusChips: some View {
        HStack(spacing: 8) {
            chip("全部", isActive: true) {}
            chip("TODO", isActive: false) { model.sidebarSelection = .todo }
            chip("暂时封存", isActive: false) { model.sidebarSelection = .archived }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private func chip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.strongButtonText : Color.archiveText)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(isActive ? Color.strongButtonBackground : Color.raised))
                .overlay {
                    if !isActive {
                        Capsule().strokeBorder(Color.rule, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .accessibilityLabel("\(label)项目")
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(projects) { project in
                    ArchiveProjectRow(
                        name: project.name,
                        status: project.status,
                        tags: (model.projectTags[project.id] ?? []).map(\.name),
                        memberCount: model.projectMembers[project.id]?.count ?? 0,
                        isSelected: model.selectedProject?.id == project.id)
                        .contextMenu {
                            Button("打开项目档案") { model.open(project: project) }
                        }
                        .onTapGesture { model.open(project: project) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        ArchiveEmptyState(
            symbolName: "lightbulb",
            title: filter == nil ? "还没有项目" : "这个状态下来还没有项目",
            message: "在线索台接受建议时选择或新建项目；也可以直接在这里创建，再把草稿加进来。新项目默认为「待整理」。",
            primaryTitle: "新建项目",
            primaryAction: { showCreate = true })
    }
}

/// 新建项目（R-005：只要求名称；默认待整理；候选组名不自动成为项目名）。
struct NewProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建项目")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            TextField("项目名称", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("新项目默认为「待整理」。一个草稿可以属于多个项目。")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    Task {
                        await model.createProject(name: name)
                        dismiss()
                    }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .archiveSheet()
    }
}
