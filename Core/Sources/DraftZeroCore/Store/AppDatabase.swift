import Foundation
import GRDB
import os

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
    /// V0.1.0 修正：组件扩展被系统强制沙盒运行（未沙盒的扩展不会进入组件画廊），
    /// 共享数据的唯一可靠位置是 App Group 容器；主应用不沙盒但接入同一
    /// App Group entitlement（App/DraftZero.entitlements），双端定位一致。
    public static let appGroupId = "group.com.draftzero.shared"

    /// App Group 容器内的共享工作区目录；entitlement 未生效（containerURL 为 nil）
    /// 时返回 nil，由调用方决定回退（回退时必须记录，不得静默切换）。
    public static func groupWorkspaceDirectory() -> URL? {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let dir = group.appendingPathComponent("DraftZero", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func groupDatabaseURL() -> URL? {
        groupWorkspaceDirectory()?.appendingPathComponent("DraftZero.sqlite")
    }

    public static func groupSnapshotsDirectory() -> URL? {
        groupWorkspaceDirectory()?.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 本机工作区目录：应用自己的 Application Support/DraftZero。
    /// V0.1.0 起为迁移来源与 entitlement 未生效时的回退位置；新数据一律进
    /// App Group 容器（见 defaultDatabaseURL 与 migrateLegacyWorkspaceIfNeeded）。
    public static func applicationSupportDatabaseURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DraftZero", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DraftZero.sqlite")
    }

    /// 本机快照目录（迁移来源；与库同目录）。
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

    /// 默认库位置：`DZ_WORKSPACE_DIR` 覆盖（QA 隔离）优先，其次 App Group 共享容器
    /// （主应用与沙盒化的组件扩展双端一致，R-009）。entitlement 未生效的罕见情形
    /// 回退应用自有目录——回退必须发生在 entitlement 确实接入并实测过的构建里，
    /// 且以 os_log fault 记录，不得作为发布版的常规路径。
    public static func defaultDatabaseURL() -> URL {
        if let base = workspaceDirectoryOverride() {
            return base.appendingPathComponent("DraftZero.sqlite")
        }
        if let shared = groupDatabaseURL() {
            return shared
        }
        faultLog("App Group 容器不可用，回退 Application Support（entitlement 未生效？）")
        return applicationSupportDatabaseURL()
    }

    private static func faultLog(_ message: String) {
        Logger(subsystem: "com.draftzero.core", category: "workspace")
            .fault("\(message, privacy: .public)")
    }

    /// 二进制快照（PDF 等）目录：定位逻辑与 defaultDatabaseURL 一致。
    public static func defaultSnapshotsURL() -> URL {
        if let base = workspaceDirectoryOverride() {
            let dir = base.appendingPathComponent("snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let dir = groupSnapshotsDirectory() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = applicationSupportSnapshotsURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 一次性迁移的结果：快照绝对路径需要从旧前缀改写到新前缀。
    public struct LegacyWorkspaceMigration: Sendable, Equatable {
        public let snapshotsOldPrefix: String
        public let snapshotsNewPrefix: String
    }

    /// 把应用自有 Application Support 工作区成套迁移进 App Group 容器（V0.1.0 起）。
    /// 只应由主应用在打开数据库之前调用；组件扩展不迁移（避免双端竞争）。
    /// 规则：
    ///   - 迁移完成标记（`.migrated-from-app-support-v1`）存在 → 不再执行；
    ///   - 旧库不存在（全新安装）→ 只写标记；
    ///   - 目标已有库：0 草稿（扩展预建/旧试验残留）→ 先改名留档再迁入；
    ///     含草稿 → 不迁移不覆盖，返回 nil 留待人工处理；
    ///   - 复制含数据库、WAL/SHM 与快照目录；全部成功才写标记，失败下次重试。
    @discardableResult
    public static func migrateLegacyWorkspaceIfNeeded(
        groupDir: URL? = nil, legacyDir: URL? = nil
    ) -> LegacyWorkspaceMigration? {
        let fm = FileManager.default
        let shared = groupDir ?? groupWorkspaceDirectory()
        guard let shared else {
            faultLog("App Group 容器不可用，跳过迁移")
            return nil
        }
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let marker = shared.appendingPathComponent(".migrated-from-app-support-v1")
        guard !fm.fileExists(atPath: marker.path) else { return nil }

        let legacyHome = legacyDir
            ?? applicationSupportDatabaseURL().deletingLastPathComponent()
        let legacyDB = legacyHome.appendingPathComponent("DraftZero.sqlite")
        let legacySnapshots = legacyHome.appendingPathComponent("snapshots", isDirectory: true)
        let sharedDB = shared.appendingPathComponent("DraftZero.sqlite")
        let sharedSnapshots = shared.appendingPathComponent("snapshots", isDirectory: true)

        func writeMarker() {
            try? Data().write(to: marker)
        }

        guard fm.fileExists(atPath: legacyDB.path) else {
            writeMarker()
            return nil
        }

        // 目标已有库：0 草稿 → 留档改名后迁入；有数据 → 不动。
        if fm.fileExists(atPath: sharedDB.path) {
            var existingDrafts: Int?
            if let existingPool = try? DatabasePool(path: sharedDB.path) {
                existingDrafts = try? existingPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft") ?? -1
                }
            }
            switch existingDrafts {
            case 0:
                let stamp = Int(Date().timeIntervalSince1970)
                for suffix in ["", "-wal", "-shm"] {
                    let from = sharedDB.path + suffix
                    if fm.fileExists(atPath: from) {
                        try? fm.moveItem(
                            atPath: from,
                            toPath: sharedDB.path + ".pre-migration-\(stamp)\(suffix)")
                    }
                }
            case let count?:
                faultLog("App Group 库已有 \(count) 份草稿，跳过迁移（需人工核对）")
                return nil
            default:
                // 库存在但打不开（损坏/加密）：同样留档后迁入。
                let stamp = Int(Date().timeIntervalSince1970)
                try? fm.moveItem(
                    atPath: sharedDB.path,
                    toPath: sharedDB.path + ".pre-migration-broken-\(stamp)")
            }
        }

        for suffix in ["", "-wal", "-shm"] {
            let from = legacyDB.path + suffix
            if fm.fileExists(atPath: from), !fm.fileExists(atPath: sharedDB.path + suffix) {
                do {
                    try fm.copyItem(atPath: from, toPath: sharedDB.path + suffix)
                } catch {
                    faultLog("迁移数据库失败：\(error.localizedDescription)")
                    return nil
                }
            }
        }

        try? fm.createDirectory(at: sharedSnapshots, withIntermediateDirectories: true)
        if fm.fileExists(atPath: legacySnapshots.path) {
            if let files = try? fm.contentsOfDirectory(
                at: legacySnapshots, includingPropertiesForKeys: nil) {
                for file in files {
                    let target = sharedSnapshots.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: target.path) {
                        try? fm.copyItem(at: file, to: target)
                    }
                }
            }
        }

        writeMarker()
        return LegacyWorkspaceMigration(
            snapshotsOldPrefix: legacySnapshots.path,
            snapshotsNewPrefix: sharedSnapshots.path)
    }

    /// 搬运旧库（含 WAL 文件）；返回是否发生了搬运。
    /// 保留给未来的容器间搬迁场景；V0.1.0 的默认迁移走 migrateLegacyWorkspaceIfNeeded。
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

    /// 一次性修正快照绝对路径前缀（容器迁移后 PDF 快照指向新位置）。
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
