import SwiftUI
import DraftZeroCore

/// 主窗口（UI-02）：顶部仅搜索与新草稿；左侧自定义「索引脊背」；
/// 主区为完整页面——草稿详情、项目档案与新稿覆盖在列表页之上，
/// 返回后原列表的筛选与滚动位置保持不变。
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var menuStore = ArchiveMenuStore()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 0) {
                TopBar()
                if let qaDir = model.workspaceOverrideDirectory {
                    WorkspaceOverrideBanner(directory: qaDir)
                }
                Divider().overlay(Color.rule)
                HStack(spacing: 0) {
                    IndexRail(width: railWidth(for: width))
                    Divider().overlay(Color.rule)
                    MainArea(width: width)
                }
            }
            .coordinateSpace(name: ArchiveMenuSpace.name)
            .overlay {
                // 档案风格下拉菜单：绘制在主窗口内部的顶层浮层
                //（不用 .popover——其瞬态窗口创建会触发本机 Metal 崩溃，见 ArchiveMenu.swift）
                ArchiveMenuOverlay(windowSize: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .environmentObject(menuStore)
        .background(Color.canvas)
        .frame(minWidth: 820, minHeight: 620)
        .sheet(item: $model.importSession) { session in
            ImportSessionView(session: session)
        }
        .sheet(isPresented: $model.showAddLinkSheet) {
            AddLinkSheet()
        }
        .sheet(isPresented: $model.showQuickSearch) {
            QuickSearchSheet()
        }
        .alert("无法打开工作区", isPresented: .init(
            get: { model.bootstrapError != nil },
            set: { if !$0 { model.bootstrapError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.bootstrapError ?? "")
        }
        // 外部 draftzero:// 写入需用户确认（V0.1.0 深链门控，B-1）。
        // 注意：弹窗关闭时 SwiftUI 会先通过绑定把 item 置 nil，
        // 因此“允许”必须在闭包内捕获 action，不能事后重读属性。
        .alert(item: $model.pendingDeepLinkWrite) { pending in
            Alert(
                title: Text("允许外部请求：\(pending.title)？"),
                message: Text(pending.message + "\n\n该请求通过 draftzero:// 链接到达，未经确认不会修改你的工作区。"),
                primaryButton: .default(Text("允许")) {
                    let action = pending.action
                    model.pendingDeepLinkWrite = nil
                    Task { await action() }
                },
                secondaryButton: .cancel(Text("拒绝")) {
                    model.pendingDeepLinkWrite = nil
                })
        }
    }

    /// 索引宽度：≥1280 收 232；960–1279 收 210；更窄收成 64 编号/图标栏。
    private func railWidth(for width: CGFloat) -> CGFloat {
        width >= 1280 ? 232 : (width >= 960 ? 210 : 64)
    }
}

/// QA 隔离工作区横幅：DZ_WORKSPACE_DIR 生效时始终可见，
/// 防止遗留设置让人误以为日常数据丢失（V0.1.0 B-2）。
struct WorkspaceOverrideBanner: View {
    let directory: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11))
            Text("QA 隔离工作区：\(directory.path)")
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("（非日常数据；清除请运行 launchctl unsetenv DZ_WORKSPACE_DIR）")
                .font(.system(size: 11))
                .opacity(0.75)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.archiveText)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.accent.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QA 隔离工作区已启用：\(directory.path)，当前窗口不使用日常数据")
    }
}

// MARK: - 全局顶栏（仅搜索 + 新草稿；DRAFT / ZERO 字识）

struct TopBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("DRAFT / ZERO")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Color.archiveText)
                .lineLimit(1)
                .padding(.leading, 76) // 保留红绿灯区域
            Spacer(minLength: 16)
            Button {
                model.showQuickSearch = true
            } label: {
                Label("搜索思想", systemImage: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mutedText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.raised))
                    .overlay(Capsule().strokeBorder(Color.rule, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k")
            .help("搜索草稿与项目（⌘K）")
            .accessibilityLabel("搜索思想（⌘K）")

            Button {
                model.openNewDraftPage()
            } label: {
                Label("新草稿", systemImage: "plus")
                    .labelStyle(ArchiveCompactLabelStyle())
            }
            .buttonStyle(ArchiveStrongButtonStyle())
            .keyboardShortcut("n")
            .help("新建草稿（⌘N）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.rail)
    }
}

/// 窄窗口下只留图标，但保留完整可访问名称。
struct ArchiveCompactLabelStyle: LabelStyle {
    @Environment(\.sizeCategory) private var sizeCategory

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - 索引脊背（自定义导航，非系统侧栏；01–05 + 底部设置）

struct IndexRail: View {
    @EnvironmentObject private var model: AppModel
    let width: CGFloat

    private var isCompact: Bool { width < 96 }

    private var bookmarkProjects: [Project] {
        Array(model.projects.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !isCompact {
                    Text("索 引")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mutedText)
                        .kerning(3)
                        .padding(.leading, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                } else {
                    Spacer().frame(height: 12)
                }

                ArchiveIndexItem(
                    number: "01", title: "草稿箱", count: model.drafts.count,
                    isSymbolOnly: isCompact, symbolName: "tray.2",
                    isSelected: model.sidebarSelection == .draftBox && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .draftBox
                }
                ArchiveIndexItem(
                    number: "02", title: "线索台", count: model.pendingClueCount,
                    isSymbolOnly: isCompact, symbolName: "sparkles.rectangle.stack",
                    isSelected: model.sidebarSelection == .clueDesk && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .clueDesk
                }
                ArchiveIndexItem(
                    number: "03", title: "想法项目", count: model.projects.count,
                    isSymbolOnly: isCompact, symbolName: "lightbulb",
                    isSelected: model.sidebarSelection == .projects && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .projects
                }
                ArchiveIndexItem(
                    number: "04", title: "TODO", count: model.projects.count { $0.status == .todo },
                    isSymbolOnly: isCompact, symbolName: "checklist",
                    isSelected: model.sidebarSelection == .todo && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .todo
                }
                ArchiveIndexItem(
                    number: "05", title: "暂时封存", count: model.projects.count { $0.status == .archived },
                    isSymbolOnly: isCompact, symbolName: "archivebox",
                    isSelected: model.sidebarSelection == .archived && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .archived
                }

                if !isCompact && !bookmarkProjects.isEmpty {
                    Text("项目书签")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mutedText)
                        .padding(.leading, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                    ForEach(bookmarkProjects) { project in
                        bookmarkRow(project)
                    }
                }

                Spacer(minLength: 12)
            }
            .frame(minHeight: 360)
        }
        .frame(width: width)
        .background(Color.rail)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(Color.rule)
                ArchiveIndexItem(
                    number: "06", title: "设置", count: nil,
                    isSymbolOnly: isCompact, symbolName: "gearshape",
                    isSelected: model.sidebarSelection == .settings && !hasDetail) {
                    model.closeDetailPages()
                    model.sidebarSelection = .settings
                }
            }
            // 显式宽度：索引项内含 Spacer，不约束会被 safeAreaInset 的提案撑满整列
            .frame(width: width, alignment: .leading)
            .background(Color.rail)
        }
    }

    private var hasDetail: Bool {
        model.selectedDraft != nil || model.selectedProject != nil || model.showNewDraftPage
    }

    private func bookmarkRow(_ project: Project) -> some View {
        Button {
            model.sidebarSelection = .projects
            model.open(project: project)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .strokeBorder(Color.archiveText, lineWidth: 1.2)
                    .background(Circle().fill(Color.archiveText))
                    .frame(width: 8, height: 8)
                    .opacity(project.status == .todo ? 1 : 0)
                    .overlay {
                        if project.status != .todo {
                            Circle().strokeBorder(Color.mutedText, lineWidth: 1).frame(width: 8, height: 8)
                        }
                    }
                    .accessibilityHidden(true)
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开项目 \(project.name)")
        .accessibilityLabel("项目书签：\(project.name)，\(project.status.displayName)")
    }
}

// MARK: - 主区（列表页常驻底层；详情/新稿以完整页面覆盖）

struct MainArea: View {
    @EnvironmentObject private var model: AppModel
    let width: CGFloat

    private var hasDetail: Bool {
        model.showNewDraftPage || model.selectedDraft != nil || model.selectedProject != nil
    }

    var body: some View {
        ZStack {
            listPage
                .allowsHitTesting(!hasDetail)
                .accessibilityHidden(hasDetail)

            if model.showNewDraftPage {
                NewDraftPage()
            } else if let draft = model.selectedDraft {
                DraftDetailView(draft: draft, width: width)
            } else if let project = model.selectedProject {
                ProjectDetailView(project: project, width: width)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
    }

    @ViewBuilder
    private var listPage: some View {
        switch model.sidebarSelection {
        case .draftBox: DraftBoxView(width: width)
        case .clueDesk: ClueDeskView(width: width)
        case .projects: ProjectsView(filter: nil)
        case .todo: ProjectsView(filter: .todo)
        case .archived: ProjectsView(filter: .archived)
        case .settings: SettingsView()
        }
    }
}
