import SwiftUI
import UniformTypeIdentifiers
import os

/// 仅 Debug 的只读探针（R-012 / 收尾 P2）：记录应用实际读到的系统
/// “减少动态效果”环境值，供实机验证（正式版不显示任何调试文案）。
#if DEBUG
struct ReduceMotionProbe: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .task {
                Logger(subsystem: "com.draftzero.app", category: "accessibility")
                    .notice("accessibilityReduceMotion(启动读取) = \(reduceMotion, privacy: .public)")
            }
            .onChange(of: reduceMotion) { _, newValue in
                Logger(subsystem: "com.draftzero.app", category: "accessibility")
                    .notice("accessibilityReduceMotion(系统切换) = \(newValue, privacy: .public)")
            }
    }
}
#endif

@main
struct DraftZeroApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // 单窗口工作台（R-012）：深链/组件入口都路由到同一窗口，不堆积新窗口
        Window("Draft Zero", id: "main") {
            MainWindowView()
                .environmentObject(model)
                #if DEBUG
                .modifier(ReduceMotionProbe())
                #endif
                .task {
                    await model.bootstrap()
                    await model.bootstrapSemantic()
                }
                .onOpenURL { url in
                    // 深链：桌面组件"新建草稿"（R-009）+ 快捷指令/自动化路由
                    Task { await model.routeDeepLink(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        Task { await model.flushAllVersions() }
                    case .active:
                        Task { await model.reload() } // 与组件改动最终一致（R-009）
                    default:
                        break
                    }
                }
        }
        // 索引档案：自定义顶栏（隐藏系统标题栏），浅/深外观随系统
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760) // SPEC 建议默认窗口
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建草稿") { model.openNewDraftPage() }
                    .keyboardShortcut("n")
                Button("导入本地文件…") { model.pickAndImport() }
                    .keyboardShortcut("o")
                Button("添加链接…") { model.showAddLinkSheet = true }
                    .keyboardShortcut("l")
                Button("快速找…") { model.showQuickSearch = true }
                    .keyboardShortcut("k")
            }
            CommandMenu("前往") {
                // 索引键盘直达（R-012 键盘可操作性）
                Button("草稿箱") { model.closeDetailPages(); model.sidebarSelection = .draftBox }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("线索台") { model.closeDetailPages(); model.sidebarSelection = .clueDesk }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("想法项目") { model.closeDetailPages(); model.sidebarSelection = .projects }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("TODO") { model.closeDetailPages(); model.sidebarSelection = .todo }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("暂时封存") { model.closeDetailPages(); model.sidebarSelection = .archived }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("设置") { model.closeDetailPages(); model.sidebarSelection = .settings }
                    .keyboardShortcut("6", modifiers: [.command])
            }
        }
    }
}
