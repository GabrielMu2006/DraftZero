import Foundation
import GRDB

/// 本机工作区数据库（R-011）。所有草稿正文、版本、项目、关系存于同一 SQLite 库，
/// 检索索引属可重建数据，后续 T-004 另建，不入此迁移。
public struct AppDatabase: Sendable {
    public let pool: any DatabaseWriter

    public init(pool: any DatabaseWriter) throws {
        self.pool = pool
        try Self.migrator.migrate(pool)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "draft") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("content", .text)
                t.column("isEditable", .boolean).notNull().defaults(to: true)
                t.column("hasExtractableText", .boolean).notNull().defaults(to: true)
                t.column("sourceType", .text).notNull()
                t.column("sourceLocation", .text)
                t.column("sourceLabel", .text)
                t.column("snapshotFileURL", .text)
                t.column("fingerprint", .text).indexed()
                t.column("importedAt", .datetime).notNull()
            }

            try db.create(table: "draftVersion") { t in
                t.primaryKey("id", .blob)
                t.column("draftId", .blob).notNull().indexed().references("draft", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "evolutionRelation") { t in
                t.primaryKey("id", .blob)
                // 不级联删除：来源草稿删除后关系保留，界面显示"来源已删除"（R-011）。
                t.column("sourceDraftId", .blob).notNull().indexed()
                t.column("targetDraftId", .blob).notNull().indexed()
                t.column("type", .text).notNull()
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("notes", .text)
                t.column("status", .text).notNull().defaults(to: ProjectStatus.inbox.rawValue)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "tag") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().unique()
            }

            try db.create(table: "projectTag") { t in
                t.column("projectId", .blob).notNull().references("project", onDelete: .cascade)
                t.column("tagId", .blob).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["projectId", "tagId"])
            }

            // 多项目归属（R-005）；删除项目或草稿只动本表，草稿内容仍在。
            try db.create(table: "projectDraft") { t in
                t.column("projectId", .blob).notNull().references("project", onDelete: .cascade)
                t.column("draftId", .blob).notNull().references("draft", onDelete: .cascade)
                t.primaryKey(["projectId", "draftId"])
            }
            try db.create(indexOn: "projectDraft", columns: ["draftId"])
        }

        // v2: 外部快照的版本标识（R-002：GitHub 保存所读版本的标识）。
        migrator.registerMigration("v2") { db in
            try db.alter(table: "draft") { t in
                t.add(column: "sourceVersionSha", .text)
            }
        }

        // v3: 语义索引（可重建）与候选对（含用户裁决与抑制记录，R-004）。
        migrator.registerMigration("v3") { db in
            try db.create(table: "indexChunk") { t in
                t.column("draftId", .blob).notNull().references("draft", onDelete: .cascade)
                t.column("chunkIndex", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("heading", .text)
                t.column("embedding", .blob).notNull()
                t.primaryKey(["draftId", "chunkIndex"])
            }
            try db.create(table: "indexStatus") { t in
                t.column("draftId", .blob).primaryKey().references("draft", onDelete: .cascade)
                t.column("fingerprint", .text).notNull()
                t.column("indexedAt", .datetime).notNull()
            }
            try db.create(table: "candidatePair") { t in
                t.primaryKey("id", .blob)
                t.column("draftA", .blob).notNull().references("draft", onDelete: .cascade)
                t.column("draftB", .blob).notNull().references("draft", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("score", .double).notNull()
                t.column("evidence", .text)
                t.column("status", .text).notNull()
                t.column("fingerprintA", .text)
                t.column("fingerprintB", .text)
                t.column("lastDecision", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("decidedAt", .datetime)
            }
            try db.create(indexOn: "candidatePair", columns: ["status"])
        }

        // v4: 远程分析建议（R-010）。建议只是建议；引用必须通过草稿原文校验才展示。
        migrator.registerMigration("v4") { db in
            try db.create(table: "remoteSuggestion") { t in
                t.primaryKey("id", .blob)
                t.column("provider", .text).notNull()
                t.column("model", .text)
                t.column("draftIdsData", .blob)
                t.column("explanation", .text)
                t.column("citationsData", .blob)
                t.column("notice", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("dismissed", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }

    /// App Group（R-009）：主应用与桌面组件共享同一份本机数据。
    /// V0.1.0 分发为未签名、未沙盒构建，未接入该 entitlement（见 defaultDatabaseURL）；
    /// 此常量与下方搬运/改路工具保留给未来启用沙盒 + App Group 的版本。
    public static let appGroupId = "group.com.draftzero.shared"

    /// 本机工作区目录：应用自己的 Application Support/DraftZero。
    /// V0.1.0 起 Debug 与 Release、主应用与组件扩展统一使用这一位置——
    /// 未接入 App Group entitlement 时 `containerURL` 仍会返回共享容器，
    /// 但该位置对分发包不可依赖（实机出现过 Release 静默切到空库），
    /// 因此在真正启用沙盒前，App Group 分支不参与默认定位。
    public static func applicationSupportDatabaseURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DraftZero", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DraftZero.sqlite")
    }

    /// 本机快照目录（PDF 等二进制快照，与库同目录）。
    public static func applicationSupportSnapshotsURL() -> URL {
        applicationSupportDatabaseURL().deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// QA 隔离工作区覆盖（收尾方案 P4）：主应用与组件扩展都必须经过这里，
    /// 保证时间线读取与 AppIntent 写入命中同一个隔离库；
    /// 默认用户库的路径与数据不受影响。设置方式：
    /// 主应用进程环境变量，或 `launchctl setenv DZ_WORKSPACE_DIR …`
    /// （组件扩展进程由系统拉起，从用户 launchd 会话继承该变量）。
    public static func workspaceDirectoryOverride() -> URL? {
        guard let raw = getenv("DZ_WORKSPACE_DIR"),
              let dir = String(validatingCString: raw),
              !dir.isEmpty else { return nil }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 默认库位置：未沙盒分发构建的唯一、可验证定位为 Application Support/DraftZero，
    /// Debug 与 Release、主应用与组件扩展完全一致（R-009）。不尝试 App Group：
    /// 权限未接入时不能依赖共享容器，更不可静默切到新空库。未来启用沙盒时，
    /// 在接入 entitlement 的构建里改为优先 App Group，并用 copyLegacyDatabase +
    /// relocateSnapshotPaths 成套迁移数据库/WAL/快照，且迁移失败不得覆盖旧数据。
    /// `DZ_WORKSPACE_DIR` 覆盖优先于一切（QA 隔离；主应用界面会显示隔离提示）。
    public static func defaultDatabaseURL() -> URL {
        if let base = workspaceDirectoryOverride() {
            return base.appendingPathComponent("DraftZero.sqlite")
        }
        return applicationSupportDatabaseURL()
    }

    /// 搬运旧库（含 WAL 文件）；返回是否发生了搬运。
    /// V0.1.0 中 Debug 与 Release 同路径，无默认迁移；此工具保留给未来
    /// 启用沙盒 + App Group 时成套搬移，失败不删除旧数据。
    @discardableResult
    public static func copyLegacyDatabase(to sharedDB: URL) -> Bool {
        let legacy = applicationSupportDatabaseURL()
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        for suffix in ["", "-wal", "-shm"] {
            let from = legacy.path + suffix
            let to = sharedDB.path + suffix
            if FileManager.default.fileExists(atPath: from), !FileManager.default.fileExists(atPath: to) {
                try? FileManager.default.copyItem(atPath: from, toPath: to)
            }
        }
        return true
    }

    /// 二进制快照（PDF 等）目录：与库同容器，定位逻辑与 defaultDatabaseURL 一致。
    public static func defaultSnapshotsURL() -> URL {
        if let base = workspaceDirectoryOverride() {
            let dir = base.appendingPathComponent("snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = applicationSupportSnapshotsURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 一次性修正快照绝对路径前缀（未来容器迁移后 PDF 快照指向新位置）。
    public func relocateSnapshotPaths(from oldPrefix: String, to newPrefix: String) async throws {
        try await pool.write { db in
            let rows = try Draft.filter(Column("snapshotFileURL") != nil).fetchAll(db)
            for var row in rows {
                if let path = row.snapshotFileURL, path.hasPrefix(oldPrefix) {
                    row.snapshotFileURL = newPrefix + path.dropFirst(oldPrefix.count)
                    try row.update(db)
                }
            }
        }
    }
}
