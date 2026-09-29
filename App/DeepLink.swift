import Foundation
import DraftZeroCore

/// 外部 draftzero:// 写入型深链的待确认请求（V0.1.0 深链门控）。
struct PendingDeepLinkWrite: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () async -> Void
}

/// 深链路由（快捷指令/自动化支持，同时服务桌面组件与测试）：
///   draftzero://new-draft                     → 打开新建草稿面板（组件入口）
///   draftzero://new-draft?title=X&content=Y   → 创建草稿（写入，Release 需确认）
///   draftzero://import?path=/tmp/x.txt        → 导入本地文件（写入，Release 需确认）
///   draftzero://tab/clues|drafts|projects|... → 切换侧边栏页面
///   draftzero://project/new?name=X            → 新建项目（写入，Release 需确认）
///   draftzero://status?project=X&status=todo  → 修改项目状态（写入，Release 需确认）
///
/// V0.1.0 安全边界：组件所需的 `new-draft`（无内容）与只读导航直接执行；
/// 其余写入型路由在 Release 构建中必须经应用内二次确认才会触库，
/// 防止任意外部进程通过 URL 静默改写工作区（快捷指令保留可用，授权流程见确认弹窗）。
extension AppModel {

    func routeDeepLink(_ url: URL) async {
        guard url.scheme?.lowercased() == "draftzero" else { return }
        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch host {
        case "new-draft":
            if let title = q("title"), !title.trimmingCharacters(in: .whitespaces).isEmpty {
                let content = q("content") ?? ""
                var message = "来自外部链接的请求要在 Draft Zero 创建草稿「\(title)」。"
                if !content.isEmpty {
                    message += "\n内容预览：\(content.prefix(80))\(content.count > 80 ? "…" : "")"
                }
                await gatedWrite("创建草稿", message) {
                    await self.createDraft(title: title, content: content)
                }
            } else {
                showNewDraftPage = true
            }
        case "import":
            if let path = q("path")?.removingPercentEncoding {
                await gatedWrite("导入文件", "来自外部链接的请求要导入本地文件：\n\(path)") {
                    await self.importFiles(at: [URL(fileURLWithPath: path)])
                }
            }
        case "import-dir":
            // 批量导入目录下全部受支持文件（逐项报告，失败不互相影响）
            if let path = q("path")?.removingPercentEncoding {
                await gatedWrite("批量导入", "来自外部链接的请求要导入目录中全部受支持文件：\n\(path)") {
                    if let files = try? FileManager.default.contentsOfDirectory(
                        at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil) {
                        let supported = files
                            .filter { !$0.lastPathComponent.hasPrefix(".") }
                            .filter { LocalFileImporter.supportedExtensions.contains(
                                $0.pathExtension.lowercased()) }
                            .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        await self.importFiles(at: supported)
                    }
                }
            }
        case "tab":
            switch url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() {
            case "clues": sidebarSelection = .clueDesk
            case "projects": sidebarSelection = .projects
            case "todo": sidebarSelection = .todo
            case "archived": sidebarSelection = .archived
            case "settings": sidebarSelection = .settings
            default: sidebarSelection = .draftBox
            }
        case "project":
            if url.path == "/new", let name = q("name") {
                await gatedWrite("新建项目", "来自外部链接的请求要创建项目「\(name)」。") {
                    await self.createProject(name: name)
                }
                sidebarSelection = .projects
            }
            if url.path == "/open", let name = q("name") {
                sidebarSelection = .projects
                if let project = projects.first(where: { $0.name == name }) {
                    select(project: project)
                }
            }
            if url.path == "/tab", let name = q("name"),
               let project = projects.first(where: { $0.name == name }) {
                sidebarSelection = .projects
                select(project: project)
                if q("tab") == "evolution" {
                    projectDetailSection = .evolution
                }
            }
        case "pair":
            // 自动化：选中第 N 条待审线索（按分数排序）；只读选中，不触库
            if let index = Int(q("index") ?? "") {
                let sorted = (leadPairs + duplicatePairs).sorted { $0.score > $1.score }
                if sorted.indices.contains(index) {
                    sidebarSelection = .clueDesk
                    selectedCluePairID = sorted[index].id
                }
            }
        case "accept-pair":
            // 自动化：接受第 N 条线索并归入项目（不存在则新建；与界面确认路径一致）
            if let index = Int(q("index") ?? "") {
                let sorted = (leadPairs + duplicatePairs).sorted { $0.score > $1.score }
                if sorted.indices.contains(index) {
                    let pair = sorted[index]
                    let projectName = q("project") ?? "待命名线索组"
                    await gatedWrite(
                        "接受线索",
                        "来自外部链接的请求要接受第 \(index + 1) 条候选线索，并归入项目「\(projectName)」（项目不存在时会新建）。") {
                        if let project = self.projects.first(where: { $0.name == projectName }) {
                            await self.acceptPair(pair, intoProject: project)
                        } else {
                            await self.createProjectAndAccept(projectName, pair: pair)
                        }
                    }
                    sidebarSelection = .clueDesk
                    selectedCluePairID = nil
                }
            }
        case "reject-pair":
            // 自动化：标记第 N 条线索为不相关（对应文档关系进入已拒绝，草稿与项目不变）
            if let index = Int(q("index") ?? "") {
                let sorted = (leadPairs + duplicatePairs).sorted { $0.score > $1.score }
                if sorted.indices.contains(index) {
                    let pair = sorted[index]
                    await gatedWrite(
                        "标记不相关",
                        "来自外部链接的请求要把第 \(index + 1) 条候选线索标记为不相关（草稿与项目不变）。") {
                        await self.rejectPair(pair)
                    }
                    sidebarSelection = .clueDesk
                }
            }
        case "defer-pair":
            // 自动化：暂缓第 N 条线索（留在稍后处理）
            if let index = Int(q("index") ?? "") {
                let sorted = (leadPairs + duplicatePairs).sorted { $0.score > $1.score }
                if sorted.indices.contains(index) {
                    let pair = sorted[index]
                    await gatedWrite(
                        "暂缓线索",
                        "来自外部链接的请求要暂缓第 \(index + 1) 条候选线索（留在稍后处理）。") {
                        await self.deferPair(pair)
                    }
                    sidebarSelection = .clueDesk
                }
            }
        case "split":
            // 自动化：把某草稿的第 N 段拆为新草稿（源不变）
            if let title = q("draft"), let para = Int(q("paragraph") ?? ""),
               let draft = drafts.first(where: { $0.title == title }),
               let content = draft.content {
                let parts = content.components(separatedBy: "\n\n").filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if parts.indices.contains(para) {
                    var cursor = content.startIndex
                    var offset = 0
                    for part in parts {
                        if let range = content.range(of: part, range: cursor..<content.endIndex) {
                            if part == parts[para] {
                                offset = content.distance(from: content.startIndex, to: range.lowerBound)
                                break
                            }
                            cursor = range.upperBound
                        }
                    }
                    let piece = parts[para]
                    await gatedWrite(
                        "拆分草稿",
                        "来自外部链接的请求要把草稿「\(title)」的第 \(para + 1) 段拆分为新草稿（原稿不变）。") {
                        await self.splitDraft(draft, piece: piece, offset: offset)
                    }
                }
            }
        case "merge":
            // 自动化：按给定标题顺序合并多份草稿为新草稿（来源不变）
            let titles = (q("drafts") ?? "").split(separator: "|").map(String.init)
            let ids = titles.compactMap { name in drafts.first { $0.title == name }?.id }
            if ids.count >= 2 {
                await gatedWrite(
                    "合并草稿",
                    "来自外部链接的请求要把 \(ids.count) 份草稿合并为新草稿（原稿保留）：\n\(titles.prefix(5).joined(separator: "、"))\(titles.count > 5 ? "…" : "")") {
                    await self.mergeDrafts(ids: ids, title: q("name"))
                }
            }
        case "tag":
            // 自动化：给项目加主题标签（同名不重复）
            if let projectName = q("project"), let tagName = q("name"),
               let project = projects.first(where: { $0.name == projectName }) {
                await gatedWrite("添加标签", "来自外部链接的请求要给项目「\(projectName)」添加标签「\(tagName)」。") {
                    await self.addTag(tagName, toProject: project.id)
                }
            }
        case "status":
            if let projectName = q("project"), let statusName = q("status")?.lowercased() {
                let status: ProjectStatus
                switch statusName {
                case "todo": status = .todo
                case "inprogress", "进行中": status = .inProgress
                case "mostlydone", "基本完成": status = .mostlyDone
                case "archived", "暂时封存": status = .archived
                default: status = .inbox
                }
                if let project = projects.first(where: { $0.name == projectName }) {
                    await gatedWrite(
                        "修改项目状态",
                        "来自外部链接的请求要把项目「\(projectName)」的状态改为「\(status.displayName)」。") {
                        await self.setProjectStatus(project, status: status)
                    }
                }
            }
        default:
            break
        }
    }

    /// 写入型深链统一入口：Debug 直接执行（UI 自动化与组件 QA 依赖）；
    /// Release 挂起为待确认请求，弹窗确认前绝不触库。
    /// “允许”侧的动作执行在 MainWindowView 的弹窗按钮闭包内完成：
    /// SwiftUI 关闭弹窗会先通过绑定清空 pendingDeepLinkWrite，
    /// 确认逻辑不能事后重读该属性（否则动作被丢弃）。
    private func gatedWrite(
        _ title: String, _ message: String,
        action: @escaping () async -> Void
    ) async {
        #if DEBUG
        await action()
        #else
        pendingDeepLinkWrite = PendingDeepLinkWrite(
            title: title, message: message, action: action)
        #endif
    }
}
