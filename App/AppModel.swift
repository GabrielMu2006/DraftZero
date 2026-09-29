import SwiftUI
import AppKit
import GRDB
import WidgetKit
import os
import DraftZeroCore

/// 侧边栏导航项（SPEC §3 主窗口布局）。
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case draftBox = "草稿箱"
    case clueDesk = "线索台"
    case projects = "想法项目"
    case todo = "TODO"
    case archived = "暂时封存"
    case settings = "设置"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .draftBox: "tray.2"
        case .clueDesk: "sparkles.rectangle.stack"
        case .projects: "lightbulb"
        case .todo: "checklist"
        case .archived: "archivebox"
        case .settings: "gearshape"
        }
    }
}

/// 导入批次的单项状态（R-001 逐项报告）。
enum ImportItemStatus: Equatable {
    case pending
    case running
    case success
    case duplicate(existingTitle: String)
    case failed(reason: String)
}

struct ImportItem: Identifiable {
    let id = UUID()
    let displayName: String
    let source: ImportedItem.Source?
    var status: ImportItemStatus = .pending
}

struct ImportSession: Identifiable {
    let id = UUID()
    var items: [ImportItem]
    var isRunning: Bool = true
}

/// 仓库文件浏览（R-002：先浏览列表并勾选，只导入所选）。
struct RepoEntry: Identifiable, Equatable {
    let path: String
    let size: Int
    let blobSha: String
    let isSupported: Bool
    let isTooLarge: Bool

    var id: String { path }

    var sizeLabel: String {
        size < 1024 ? "\(size) B"
            : size < 1_048_576 ? String(format: "%.0f KB", Double(size) / 1024)
            : String(format: "%.1f MB", Double(size) / 1_048_576)
    }
}

struct RepoBrowse: Identifiable {
    let id = UUID()
    let owner: String
    let repo: String
    let branch: String
    let treeSha: String
    var entries: [RepoEntry]
    var truncated: Bool
    var checked: Set<String> = []
}

/// 草稿箱筛选（UI-REDESIGN-PLAN §5.1：视图状态，不写入数据模型）。
enum DraftBoxFilter: String, CaseIterable, Hashable {
    case all = "全部"
    case ungrouped = "未归组"
    case recentlyEdited = "最近编辑"
    case snapshots = "来源快照"
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published 状态

    @Published var drafts: [Draft] = []
    @Published var projectCounts: [UUID: Int] = [:]
    @Published var draftProjects: [UUID: [String]] = [:]
    /// 每份草稿最近一次编辑时间（版本表推导；无版本回退导入时间）
    @Published var lastEdited: [UUID: Date] = [:]
    @Published var selectedDraftID: UUID?
    @Published var sidebarSelection: SidebarItem = .draftBox
    @Published var draftBoxFilter: DraftBoxFilter = .all
    @Published var importSession: ImportSession?
    /// 全页「新草稿」页（UI-04：所有入口走同一主区页面，不再是固定表单弹层）
    @Published var showNewDraftPage = false
    @Published var showAddLinkSheet = false
    @Published var showQuickSearch = false
    @Published var repoBrowse: RepoBrowse?
    @Published var linkError: String?
    @Published var linkLoading = false
    @Published var bootstrapError: String?

    // 语义线索（R-004）
    @Published var clueReport: CandidateReport?
    @Published var leadPairs: [CandidatePair] = []
    @Published var duplicatePairs: [CandidatePair] = []
    @Published var deferredLeads: [CandidatePair] = []
    @Published var rejectedLeads: [CandidatePair] = []
    @Published var semanticState: SemanticState = .idle

    // 项目（R-005/R-008）
    @Published var projects: [Project] = []
    @Published var projectTags: [UUID: [Tag]] = [:]
    @Published var projectMembers: [UUID: [Draft]] = [:]
    @Published var selectedProjectID: UUID?
    @Published var selectedCluePairID: UUID?

    // 演化关系（R-007）
    @Published var draftRelations: [UUID: [EvolutionRelation]] = [:]

    /// 项目详情的 成员/演化 分段选择（深链可切换）
    @Published var projectDetailSection: ProjectSection = .members

    // 远程分析（R-010）
    @Published var remoteEnabled = false
    @Published var remoteHasKey = false
    @Published var remoteStatus: String?
    @Published var remoteAnalyzing = false
    @Published var remoteSuggestions: [RemoteSuggestion] = []
    var remoteProvider: DeepSeekProvider?

    /// 外部 draftzero:// 写入型深链的待确认请求（V0.1.0 深链门控）：
    /// Release 中写入动作先经应用内确认，用户拒绝或忽略都不触库；
    /// Debug 直接执行，供 UI 自动化与组件 QA（见 DeepLink.swift）。
    @Published var pendingDeepLinkWrite: PendingDeepLinkWrite?

    /// QA 隔离工作区覆盖（启动时读取一次，仅用于界面提示）：
    /// 防止遗留的 DZ_WORKSPACE_DIR 让人误以为日常数据丢失。
    let workspaceOverrideDirectory: URL?

    init() {
        workspaceOverrideDirectory = AppDatabase.workspaceDirectoryOverride()
        if let dir = workspaceOverrideDirectory {
            Logger(subsystem: "com.draftzero.app", category: "workspace")
                .notice("DZ_WORKSPACE_DIR 隔离工作区启用：\(dir.path, privacy: .public)")
        }
    }

    private(set) var database: AppDatabase?
    private var importer: LocalFileImporter?
    private var webImporter: WebImporter?
    private var gitHubImporter: GitHubImporter?
    private var versioner: AutoVersioner?
    var candidateEngine: CandidateEngine?
    var embedder: TextEmbedding?

    var selectedDraft: Draft? {
        drafts.first { $0.id == selectedDraftID }
    }

    /// 待确认线索总数（草稿箱摘要与索引徽标用）：待审 + 可能重复 + 远程补充。
    var pendingClueCount: Int {
        leadPairs.count + duplicatePairs.count + remoteSuggestions.count
    }

    var ungroupedCount: Int {
        drafts.count { (projectCounts[$0.id] ?? 0) == 0 }
    }

    // MARK: - 启动

    func bootstrap() async {
        guard database == nil else { return }
        do {
            // V0.1.0：一次性把 Application Support 工作区迁入 App Group 共享容器
            // （组件扩展已沙盒化，只能访问共享容器）。仅主应用执行，可重试。
            let migration = AppDatabase.migrateLegacyWorkspaceIfNeeded()
            // 库与快照的定位统一走 Core（含 DZ_WORKSPACE_DIR 隔离覆盖），
            // 与桌面组件扩展的读取/写入同一实现（收尾方案 P4）。
            let dbURL = AppDatabase.defaultDatabaseURL()
            let snapshotsURL = AppDatabase.defaultSnapshotsURL()
            let pool = try DatabasePool(path: dbURL.path)
            let db = try AppDatabase(pool: pool)
            database = db
            if let migration {
                // 快照记录的是绝对路径：迁移后改写前缀，PDF 快照才能继续打开。
                try? await db.relocateSnapshotPaths(
                    from: migration.snapshotsOldPrefix,
                    to: migration.snapshotsNewPrefix)
            }
            importer = LocalFileImporter(database: db, snapshotsDirectory: snapshotsURL)
            webImporter = WebImporter(database: db)
            gitHubImporter = GitHubImporter(database: db, snapshotsDirectory: snapshotsURL)
            versioner = AutoVersioner(idleInterval: 60) { [db] draftId, content in
                try? await db.recordVersionIfChanged(draftId: draftId, content: content, origin: .autoSave)
            }
            await reload()
        } catch {
            bootstrapError = "无法打开本机工作区：\(error.localizedDescription)"
        }
    }

    func reload() async {
        guard let database else { return }
        drafts = (try? await database.drafts()) ?? []
        projectCounts = (try? await database.projectCountsByDraft()) ?? [:]
        projects = (try? await database.projects()) ?? []
        lastEdited = (try? await database.lastEditedByDraft()) ?? [:]
        // 保留详情栏选中：项目被删除时才清除
        if let selectedID = selectedProject?.id {
            selectedProject = projects.first { $0.id == selectedID }
        }
        await reloadProjectDetails()
        await reloadDraftProjectNames()
        notifyWidget()
    }

    /// 草稿所属项目名（草稿箱行与项目成员页展示一稿多项目，R-005）。
    private func reloadDraftProjectNames() async {
        guard let database else { return }
        var names: [UUID: [String]] = [:]
        for draft in drafts {
            let owning = (try? await database.projects(containing: draft.id)) ?? []
            names[draft.id] = owning.map(\.name)
        }
        draftProjects = names
    }

    /// 主应用数据变化后让组件时间线刷新（R-009：两端最终一致）。
    func notifyWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 当前详情栏的项目对象。
    @Published var selectedProject: Project?

    func select(project: Project) {
        selectedProject = project
        selectedDraftID = nil
    }

    /// 刷新项目标签与成员缓存（成员变化、标签变化后调用）。
    func reloadProjectDetails() async {
        guard let database else { return }
        var tags: [UUID: [Tag]] = [:]
        var members: [UUID: [Draft]] = [:]
        for project in projects {
            tags[project.id] = (try? await database.tags(onProject: project.id)) ?? []
            members[project.id] = (try? await database.drafts(inProject: project.id)) ?? []
        }
        projectTags = tags
        projectMembers = members
        if let selected = selectedProject,
           let updated = projects.first(where: { $0.id == selected.id }) {
            selectedProject = updated
        }
    }

    // MARK: - 本地文件导入（R-001）

    func importFiles(at urls: [URL]) async {
        guard let importer, !urls.isEmpty else { return }
        let before = Set(drafts.map(\.id))
        let names = urls.map { $0.lastPathComponent }
        let sources: [ImportedItem.Source?] = urls.map { .localFile($0) }
        await runBatch(names: names, sources: sources) { index in
            let outcome = await importer.importFile(at: urls[index])
            return Self.status(of: outcome)
        }
        await analyzeNewDraftsSince(previousIds: before)
    }

    /// 用户对重复项选择"另存新快照"（仅本地文件重试路径）。
    func importAnyway(itemID: UUID) async {
        guard let importer, let session = importSession,
              let index = session.items.firstIndex(where: { $0.id == itemID }),
              case .localFile(let url)? = session.items[index].source else { return }
        importSession?.items[index].status = .running
        let outcome = await importer.importFile(at: url, allowDuplicate: true)
        importSession?.items[index].status = Self.status(of: outcome)
        await reload()
    }

    /// 菜单/快捷键 Command-O：打开面板选择本地文件（R-001）。
    func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .pdf]
        panel.message = "选择要收纳的 TXT、Markdown 或 PDF 文件"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(at: urls) }
    }

    // MARK: - 链接导入：网页与 GitHub（R-002）

    /// 统一入口：网页链接直接导入；GitHub 单文件直接导入；GitHub 仓库打开勾选列表。
    func openLink(_ raw: String) async {
        guard let web = webImporter, let github = gitHubImporter else { return }
        linkError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let before = Set(drafts.map(\.id))

        if let ref = GitHubLinkParser.parse(trimmed) {
            switch ref.kind {
            case .repo:
                await openRepo(ref, github: github)
            case .file:
                let name = ref.path ?? "GitHub 文件"
                linkLoading = true
                defer { linkLoading = false }
                await runBatch(names: [name], sources: [nil]) { [github] _ in
                    Self.status(of: await github.importSingleFile(ref: ref))
                }
                showAddLinkSheet = false
                await analyzeNewDraftsSince(previousIds: before)
            }
            return
        }

        // 非 GitHub 链接按普通网页处理。
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            linkError = "无法识别链接：请使用 http(s) 网页或 github.com 链接"
            return
        }
        linkLoading = true
        defer { linkLoading = false }
        let name = url.host ?? url.absoluteString
        await runBatch(names: [name], sources: [nil]) { [web] _ in
            Self.status(of: await web.importWebPage(url: url))
        }
        showAddLinkSheet = false
        await analyzeNewDraftsSince(previousIds: before)
    }

    private func openRepo(_ ref: GitHubLinkParser.Ref, github: GitHubImporter) async {
        linkLoading = true
        defer { linkLoading = false }
        do {
            let branch: String
            if let known = ref.ref {
                branch = known
            } else {
                branch = try await github.client.defaultBranch(owner: ref.owner, repo: ref.repo)
            }
            let (treeSha, entries, truncated) = try await github.client.listTree(
                owner: ref.owner, repo: ref.repo, ref: branch)
            var blobs = entries.filter { $0.type == "blob" }
            if let prefix = ref.path {
                blobs = blobs.filter { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
            }
            blobs.sort { $0.path < $1.path }
            repoBrowse = RepoBrowse(
                owner: ref.owner, repo: ref.repo, branch: branch, treeSha: treeSha,
                entries: blobs.map { entry in
                    RepoEntry(
                        path: entry.path,
                        size: entry.size ?? 0,
                        blobSha: entry.sha,
                        isSupported: LocalFileImporter.supportedExtensions.contains(
                            (entry.path as NSString).pathExtension.lowercased()),
                        isTooLarge: (entry.size ?? 0) > GitHubImporter.maxTextFileSize)
                },
                truncated: truncated)
        } catch {
            linkError = error.localizedDescription
        }
    }

    /// 导入勾选的仓库文件；取消勾选即不导入任何内容（R-002）。
    func importCheckedRepoFiles() async {
        guard let github = gitHubImporter, let browse = repoBrowse else { return }
        let checked = browse.entries.filter { browse.checked.contains($0.path) }
        guard !checked.isEmpty else { return }
        let requests = checked.map {
            GitHubImportRequest(
                owner: browse.owner, repo: browse.repo, branch: browse.branch,
                treeSha: browse.treeSha, path: $0.path, blobSha: $0.blobSha)
        }
        let names = requests.map { $0.path }
        let before = Set(drafts.map(\.id))
        showAddLinkSheet = false
        repoBrowse = nil
        await runBatch(names: names, sources: requests.map { .githubFile($0) }) { [github] index in
            Self.status(of: await github.importFile(request: requests[index]))
        }
        await analyzeNewDraftsSince(previousIds: before)
    }

    // MARK: - 导入批次共用

    private func runBatch(
        names: [String],
        sources: [ImportedItem.Source?],
        perform: (_ index: Int) async -> ImportItemStatus
    ) async {
        guard !names.isEmpty else { return }
        var session = ImportSession(
            items: (0..<names.count).map { ImportItem(displayName: names[$0], source: sources[$0]) })
        importSession = session
        for index in names.indices {
            session.items[index].status = .running
            importSession = session
            let status = await perform(index)
            session.items[index].status = status
            session.isRunning = index < names.count - 1
            importSession = session
            await reload()
        }
    }

    static func status(of outcome: ImportOutcome) -> ImportItemStatus {
        switch outcome {
        case .success: .success
        case .duplicate(let existing): .duplicate(existingTitle: existing.title)
        case .failure(let reason): .failed(reason: reason)
        }
    }

    // MARK: - 新建草稿（R-001 / UI-04 全页新稿）

    /// 打开全页新稿（顶栏 ⌘N、深链、空态、组件入口共用）。
    func openNewDraftPage() {
        showNewDraftPage = true
        selectedDraftID = nil
        selectedProject = nil
    }

    /// 只有正文时自动使用有意义的临时标题（底层仍按既有创建规则处理）。
    static func fallbackTitle(for content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.isEmpty { return "" }
        return String(firstLine.prefix(24))
    }

    /// 创建草稿；返回是否成功（失败时界面保留输入并显示错误）。
    @discardableResult
    func createDraft(title: String, content: String) async -> Bool {
        guard let database else {
            newDraftError = "工作区尚未就绪，请稍后重试"
            return false
        }
        let effectiveTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.fallbackTitle(for: content)
            : title
        let before = Set(drafts.map(\.id))
        do {
            let draft = try await database.createManualDraft(title: effectiveTitle, content: content)
            await reload()
            selectedDraftID = draft.id
            await analyzeNewDraftsSince(previousIds: before)
            newDraftError = nil
            return true
        } catch {
            newDraftError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 详情页返回（保留原列表筛选与滚动位置：列表仍在主区下层）。
    func closeDetailPages() {
        showNewDraftPage = false
        selectedDraftID = nil
        selectedProject = nil
    }

    func open(draft: Draft) {
        selectedProject = nil
        showNewDraftPage = false
        selectedDraftID = draft.id
    }

    func open(project: Project) {
        selectedDraftID = nil
        showNewDraftPage = false
        selectedProject = project
    }

    // MARK: - 编辑与版本（R-003/R-006）

    /// 新稿页保存失败信息（UI-04：失败保留输入并显示具体错误）。
    @Published var newDraftError: String?

    /// 草稿编辑保存状态（UI-07：已保存 / 正在保存 / 保存失败）。
    enum EditSaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }
    @Published var editSaveState: EditSaveState = .idle

    /// 持续自动保存当前工作内容；版本由 AutoVersioner 静默 60 秒后记录。
    func saveEdit(draftId: UUID, text: String) async {
        guard let database else { return }
        editSaveState = .saving
        do {
            try await database.updateDraftContent(id: draftId, content: text)
            await versioner?.contentChanged(draftId: draftId, text: text)
            if let index = drafts.firstIndex(where: { $0.id == draftId }) {
                drafts[index].content = text
            }
            editSaveState = .saved
        } catch {
            editSaveState = .failed(error.localizedDescription)
        }
    }

    func flushVersion(draftId: UUID) async {
        await versioner?.flush(draftId: draftId)
    }

    func flushAllVersions() async {
        await versioner?.flushAll()
    }

    func restore(version: DraftVersion) async {
        guard let database else { return }
        _ = try? await database.restoreVersion(versionId: version.id)
        await reload()
    }

    // MARK: - 只读快照衍生（R-003）

    func createEditableCopy(from draft: Draft) async {
        guard let database, let content = draft.content else { return }
        if let derived = try? await database.createDerivedDraft(
            from: draft.id, title: draft.title + "（可编辑）", content: content) {
            await reload()
            selectedDraftID = derived.id
        }
    }

    // MARK: - 删除（R-011）

    /// 删除前的影响说明：所属项目与版本数。
    func deletionImpact(for draft: Draft) async -> String {
        guard let database else { return "" }
        var lines: [String] = []
        let projects = (try? await database.projects(containing: draft.id)) ?? []
        if projects.isEmpty {
            lines.append("不属于任何项目。")
        } else {
            lines.append("所属项目：" + projects.map(\.name).joined(separator: "、"))
        }
        let versionCount = (try? await database.versions(draftId: draft.id))?.count ?? 0
        lines.append("将删除正文与 \(versionCount) 个版本，相关关系将显示为「来源已删除」。")
        if draft.snapshotFileURL != nil {
            lines.append("应用内的 PDF 快照也会一并删除（原文件与远端内容不受影响）。")
        }
        return lines.joined(separator: "\n")
    }

    func deleteDraft(_ draft: Draft) async {
        guard let database else { return }
        try? await database.deleteDraft(id: draft.id)
        if let path = draft.snapshotFileURL {
            try? FileManager.default.removeItem(atPath: path)
        }
        if selectedDraftID == draft.id {
            selectedDraftID = nil
        }
        await reload()
    }
}
