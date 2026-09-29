import WidgetKit
import SwiftUI
import GRDB
import DraftZeroCore

// MARK: - 数据读取（与主应用同一份本机数据库，R-009）
//
// V0.1.0 组件形态（按产品所有者复核意见调整）：展示 TODO 与最近项目 +
// 「新建草稿」入口；项目行可点击，在主应用中打开对应项目。
// 原先的两种一键状态按钮已移除（沙盒化扩展的意图按钮在桌面表现不稳定，
// 且所有者裁定图标观感不佳）；状态修改回到主应用完成。

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
        _ = try AppDatabase(pool: pool)
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
    static let wAccent = archive(
        NSColor(red: 0x80/255, green: 0x60/255, blue: 0x2D/255, alpha: 1),
        NSColor(red: 0xE1/255, green: 0xC9/255, blue: 0x93/255, alpha: 1))
    static let wRule = archive(
        NSColor(red: 0xC8/255, green: 0xC8/255, blue: 0xBE/255, alpha: 1),
        NSColor(red: 0x59/255, green: 0x66/255, blue: 0x5C/255, alpha: 1))
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
                        projectRow(project, isTodo: true)
                    }
                }
                if !entry.recent.isEmpty {
                    sectionTitle("最近项目")
                    ForEach(entry.recent) { project in
                        projectRow(project, isTodo: false)
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

    /// 项目行：纯文字行，点击在主应用中打开该项目（只读导航深链，安全边界允许直接执行）。
    private func projectRow(_ project: WidgetProject, isTodo: Bool) -> some View {
        Link(destination: projectOpenURL(project)) {
            HStack(spacing: 6) {
                if isTodo {
                    Circle()
                        .fill(Color.wText.opacity(0.85))
                        .frame(width: 5, height: 5)
                }
                Text(project.name)
                    .font(.system(size: 12, weight: isTodo ? .medium : .regular, design: .serif))
                    .foregroundStyle(Color.wText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.wRaised, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func projectOpenURL(_ project: WidgetProject) -> URL {
        let encoded = project.name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? project.name
        return URL(string: "draftzero://project/open?name=\(encoded)")!
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
        // 主应用会在数据变化时主动刷新；这里再留一个 30 分钟兜底。
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct DraftZeroWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DraftZeroMainWidget", provider: Provider()) { entry in
            DraftZeroWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Draft Zero")
        .description("TODO 与最近项目一览，点项目在应用中打开，快速新建草稿。")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct DraftZeroWidgetBundle: WidgetBundle {
    var body: some Widget {
        DraftZeroWidget()
    }
}
