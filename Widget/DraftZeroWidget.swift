import WidgetKit
import SwiftUI
import AppIntents
import GRDB
import DraftZeroCore

// MARK: - 数据读取（与主应用同一份 App Group 数据库，R-009）

struct WidgetProject: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ProjectsEntry: TimelineEntry {
    let date: Date
    var todo: [WidgetProject]
    var recent: [WidgetProject]
    var failed: Bool
}

private func readProjectsEntry(failed: Bool = false) -> ProjectsEntry {
    var entry = ProjectsEntry(date: .now, todo: [], recent: [], failed: failed)
    do {
        let pool = try DatabasePool(path: AppDatabase.defaultDatabaseURL().path)
        let db = try AppDatabase(pool: pool)
        // 用同步读（组件进程内阻塞一次可接受）；状态与最近项目各取所需。
        let todo = try pool.read { db -> [(UUID, String)] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name FROM project WHERE status = ? ORDER BY createdAt DESC LIMIT 2
                """, arguments: [ProjectStatus.todo.rawValue])
            return rows.compactMap { row in
                guard let id = row["id"] as UUID?, let name = row["name"] as String? else { return nil }
                return (id, name)
            }
        }
        let todoIds = Set(todo.map(\.0))
        let recent = try pool.read { db -> [(UUID, String)] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name FROM project WHERE status != ? ORDER BY createdAt DESC LIMIT 4
                """, arguments: [ProjectStatus.archived.rawValue])
            return rows.compactMap { row in
                guard let id = row["id"] as UUID?, let name = row["name"] as String? else { return nil }
                return (id, name)
            }.filter { !todoIds.contains($0.0) }
        }
        entry.todo = todo.map { WidgetProject(id: $0.0.uuidString, name: $0.1) }
        entry.recent = recent.map { WidgetProject(id: $0.0.uuidString, name: $0.1) }
    } catch {
        entry.failed = true
    }
    return entry
}

// MARK: - 意图（一键改状态；失败时抛错由系统提示，不用乐观显示）

struct MarkProjectDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "标记为基本完成"
    static let openAppWhenRun = false

    @Parameter(title: "项目 ID")
    var projectId: String

    init() {}

    init(projectId: String) {
        self.projectId = projectId
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: projectId) else { return .result() }
        let pool = try DatabasePool(path: AppDatabase.defaultDatabaseURL().path)
        let db = try AppDatabase(pool: pool)
        try await db.setProjectStatus(id: id, status: .mostlyDone)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct MarkProjectTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "设为 TODO"
    static let openAppWhenRun = false

    @Parameter(title: "项目 ID")
    var projectId: String

    init() {}

    init(projectId: String) {
        self.projectId = projectId
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: projectId) else { return .result() }
        let pool = try DatabasePool(path: AppDatabase.defaultDatabaseURL().path)
        let db = try AppDatabase(pool: pool)
        try await db.setProjectStatus(id: id, status: .todo)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 视图（索引档案配色：纸面层次 + 衬线标题；随桌面浅/深背景自适应）

import SwiftUI

private extension Color {
    static func archive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let wCanvas = archive(
        NSColor(red: 0xD9/255, green: 0xD6/255, blue: 0xCC/255, alpha: 1),
        NSColor(red: 0x24/255, green: 0x2C/255, blue: 0x2A/255, alpha: 1))
    static let wRaised = archive(
        NSColor(red: 0xF1/255, green: 0xF0/255, blue: 0xE9/255, alpha: 1),
        NSColor(red: 0x30/255, green: 0x3A/255, blue: 0x34/255, alpha: 1))
    static let wText = archive(
        NSColor(red: 0x28/255, green: 0x2B/255, blue: 0x27/255, alpha: 1),
        NSColor(red: 0xEF/255, green: 0xF0/255, blue: 0xE7/255, alpha: 1))
    static let wMuted = archive(
        NSColor(red: 0x66/255, green: 0x6B/255, blue: 0x65/255, alpha: 1),
        NSColor(red: 0xC3/255, green: 0xCC/255, blue: 0xC2/255, alpha: 1))
    static let wRule = archive(
        NSColor(red: 0xC8/255, green: 0xC8/255, blue: 0xBE/255, alpha: 1),
        NSColor(red: 0x59/255, green: 0x66/255, blue: 0x5C/255, alpha: 1))
    static let wAccent = archive(
        NSColor(red: 0x80/255, green: 0x60/255, blue: 0x2D/255, alpha: 1),
        NSColor(red: 0xE1/255, green: 0xC9/255, blue: 0x93/255, alpha: 1))
    static let wConfirmed = archive(
        NSColor(red: 0x42/255, green: 0x6C/255, blue: 0x55/255, alpha: 1),
        NSColor(red: 0xA9/255, green: 0xD1/255, blue: 0xB1/255, alpha: 1))
}

struct DraftZeroWidgetEntryView: View {
    var entry: ProjectsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if entry.failed {
                Spacer()
                Text("无法读取工作区数据")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.wText)
                Text("请打开 Draft Zero 一次以完成初始化")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.wMuted)
                Spacer()
            } else if entry.todo.isEmpty && entry.recent.isEmpty {
                Spacer()
                Text("还没有项目")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.wText)
                Text("打开 Draft Zero，导入几份草稿并创建项目")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.wMuted)
                Spacer()
            } else {
                if !entry.todo.isEmpty {
                    sectionTitle("TODO")
                    ForEach(entry.todo) { project in
                        HStack(spacing: 6) {
                            Text(project.name)
                                .font(.system(size: 12, weight: .medium, design: .serif))
                                .foregroundStyle(Color.wText)
                                .lineLimit(1)
                            Spacer()
                            Button(intent: MarkProjectDoneIntent(projectId: project.id)) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(Color.wConfirmed)
                            }
                            .buttonStyle(.borderless)
                            .help("标记为基本完成")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.wRaised, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                if !entry.recent.isEmpty {
                    sectionTitle("最近项目")
                    ForEach(entry.recent) { project in
                        HStack(spacing: 6) {
                            Text(project.name)
                                .font(.system(size: 12, design: .serif))
                                .foregroundStyle(Color.wText)
                                .lineLimit(1)
                            Spacer()
                            Button(intent: MarkProjectTodoIntent(projectId: project.id)) {
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(Color.wAccent)
                            }
                            .buttonStyle(.borderless)
                            .help("设为 TODO")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.wRaised, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "draftzero://new-draft")!) {
                    Label("新建草稿", systemImage: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.wText)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { Color.wCanvas }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.wAccent)
                .frame(width: 3, height: 10)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.wMuted)
        }
        .padding(.top, 2)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ProjectsEntry {
        ProjectsEntry(
            date: .now,
            todo: [WidgetProject(id: UUID().uuidString, name: "示例项目")],
            recent: [], failed: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProjectsEntry) -> Void) {
        completion(readProjectsEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProjectsEntry>) -> Void) {
        let entry = readProjectsEntry()
        // 主应用与意图都会主动刷新；这里再留一个 30 分钟兜底。
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct DraftZeroWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DraftZeroMainWidget", provider: Provider()) { entry in
            DraftZeroWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Draft Zero")
        .description("TODO 与最近项目，一键推进状态，快速新建草稿。")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct DraftZeroWidgetBundle: WidgetBundle {
    var body: some Widget {
        DraftZeroWidget()
    }
}
