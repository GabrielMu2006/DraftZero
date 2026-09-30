import Foundation
import GRDB
import CryptoKit

/// .dzarchive —— 一次性 Mac→Windows 工作区迁移档案（V0.2.0 计划 §3，formatVersion=1）。
///
/// ZIP 容器：`manifest.json` + `data/*.json` + `pdf/<uuid>.pdf`。
/// JSON 统一 UTF-8；ID 为规范 UUID 字符串（大写）；时间为 ISO-8601 UTC；
/// ZIP 内路径全部相对，禁止绝对路径与 `..`。
/// **不导出**：可重建的向量/索引、候选分数与证据、机器绝对快照路径、
/// DeepSeek Key 或任何访问令牌（Keychain 与本导出无关）。
/// 已拒绝/暂缓/已接受的裁决行随档案迁移（保留抑制规则）；待审候选不迁移，
/// Windows 端重建索引后重新生成。
///
/// 这是**复制迁移**：导出过程只读源库；原工作区保持不变。
public enum DzArchiveExporter {

    // MARK: - 档案模型（字段名与 Windows C# 端 DzArchive.cs 契约一致）

    struct Manifest: Codable {
        var formatVersion: Int
        var application: String
        var exportedByVersion: String
        var exportedAt: String
        var files: [ManifestFile]
        var counts: Counts
    }

    struct ManifestFile: Codable {
        var path: String
        var sizeBytes: Int
        var sha256: String
    }

    struct Counts: Codable {
        var drafts: Int
        var versions: Int
        var projects: Int
        var memberships: Int
        var relations: Int
        var tags: Int
        var projectTags: Int
        var candidateDecisions: Int
        var remoteSuggestions: Int
        var pdfSnapshots: Int
    }

    struct ArchiveDraft: Codable {
        var id: String
        var title: String
        var content: String?
        var isEditable: Bool
        var hasExtractableText: Bool
        var sourceType: String
        var sourceLocation: String?
        var sourceLabel: String?
        var fingerprint: String?
        var sourceVersionSha: String?
        var importedAt: String
        /// 档案内 PDF 快照相对路径（如 "pdf/xx.pdf"）；非 PDF 为 nil。
        var snapshotFile: String?
    }

    struct ArchiveVersion: Codable {
        var id: String
        var draftId: String
        var content: String
        var origin: String
        var createdAt: String
    }

    struct ArchiveRelation: Codable {
        var id: String
        var sourceDraftId: String
        var targetDraftId: String
        var type: String
        var note: String?
        var createdAt: String
    }

    struct ArchiveProject: Codable {
        var id: String
        var name: String
        var notes: String?
        var status: String
        var createdAt: String
    }

    struct ArchiveMembership: Codable {
        var projectId: String
        var draftId: String
    }

    struct ArchiveTags: Codable {
        var tags: [ArchiveTag]
        var memberships: [ArchiveProjectTag]
    }

    struct ArchiveTag: Codable {
        var id: String
        var name: String
    }

    struct ArchiveProjectTag: Codable {
        var projectId: String
        var tagId: String
    }

    /// 候选裁决行：不含分数与证据（可重建数据不迁移）。
    struct ArchiveCandidateDecision: Codable {
        var id: String
        var draftA: String
        var draftB: String
        var kind: String
        var status: String
        var fingerprintA: String?
        var fingerprintB: String?
        var lastDecision: String?
        var createdAt: String
        var decidedAt: String?
    }

    struct ArchiveRemoteSuggestion: Codable {
        var id: String
        var provider: String
        var model: String?
        var draftIds: [String]
        var explanation: String?
        var citations: [ArchiveCitation]?
        var notice: String?
        var createdAt: String
        var dismissed: Bool
    }

    struct ArchiveCitation: Codable {
        var draftId: String
        var quote: String
    }

    public enum ExportError: LocalizedError {
        case notADraftZeroDatabase
        case snapshotMissing(String)
        case unsupportedSourceType(String)
        case unsupportedVersionOrigin(String)
        case unsupportedRelationType(String)
        case unsupportedProjectStatus(String)
        case unsupportedCandidateStatus(String)

        public var errorDescription: String? {
            switch self {
            case .notADraftZeroDatabase: "当前库不是 DraftZero 工作区数据库，已停止导出"
            case .snapshotMissing(let p): "PDF 快照文件缺失：\(p)"
            case .unsupportedSourceType(let v): "草稿来源类型不可识别：\(v)"
            case .unsupportedVersionOrigin(let v): "版本来源不可识别：\(v)"
            case .unsupportedRelationType(let v): "关系类型不可识别：\(v)"
            case .unsupportedProjectStatus(let v): "项目状态不可识别：\(v)"
            case .unsupportedCandidateStatus(let v): "候选状态不可识别：\(v)"
            }
        }
    }

    // MARK: - 导出入口

    /// - Parameters:
    ///   - database: 已迁移的 Mac 工作区库（只读访问）。
    ///   - snapshotsDirectory: 库同目录的 snapshots 目录（PDF 快照所在）。
    ///   - destination: 目标 .dzarchive 路径；已存在时先删除重写。
    ///   - appVersion: 记入 manifest 的导出应用版本（如 "0.2.0"）。
    /// - Returns: 实际写出路径。
    @discardableResult
    public static func export(
        database: AppDatabase, snapshotsDirectory: URL,
        to destination: URL, appVersion: String
    ) async throws -> URL {
        let pool = database.pool

        // 1. 读取全部数据（单次快照读，不阻塞写入队列太久）。
        let drafts = try await pool.read { db in
            try Draft.order(Column("importedAt").asc).fetchAll(db)
        }
        let versions = try await pool.read { db in
            try DraftVersion.order(sql: "createdAt ASC, rowid ASC").fetchAll(db)
        }
        let relations = try await pool.read { db in
            try EvolutionRelation.order(Column("createdAt").asc).fetchAll(db)
        }
        let projects = try await pool.read { db in
            try Project.order(Column("createdAt").asc).fetchAll(db)
        }
        let tags = try await pool.read { db in try Tag.order(Column("name").asc).fetchAll(db) }
        let projectTags = try await pool.read { db in try ProjectTag.order(sql: "projectId, tagId").fetchAll(db) }
        let memberships = try await pool.read { db in
            try ProjectDraft.order(sql: "projectId, draftId").fetchAll(db)
        }
        // 裁决行（accepted/rejected/deferred）；待审不迁移（分数是可重建数据）。
        let decisions = try await pool.read { db in
            let status = Column("status")
            return try CandidatePair
                .filter(status != CandidateStatus.pending.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
        let suggestions = try await pool.read { db in
            try RemoteSuggestion.filter(Column("dismissed") == false)
                .order(Column("createdAt").asc).fetchAll(db)
        }

        // 2. 组装档案 JSON。
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var archiveDrafts: [ArchiveDraft] = []
        var pdfEntries: [(entryPath: String, sourceURL: URL)] = []
        for draft in drafts {
            var snapshotFile: String?
            if let snapshotPath = draft.snapshotFileURL {
                let sourceURL = URL(fileURLWithPath: snapshotPath)
                guard FileManager.default.fileExists(atPath: snapshotPath) else {
                    throw ExportError.snapshotMissing(snapshotPath)
                }
                let entry = "pdf/" + sourceURL.lastPathComponent
                snapshotFile = entry
                pdfEntries.append((entry, sourceURL))
            }
            archiveDrafts.append(ArchiveDraft(
                id: draft.id.uuidString,
                title: draft.title,
                content: draft.content,
                isEditable: draft.isEditable,
                hasExtractableText: draft.hasExtractableText,
                sourceType: draft.sourceType.rawValue,
                sourceLocation: draft.sourceLocation,
                sourceLabel: draft.sourceLabel,
                fingerprint: draft.fingerprint,
                sourceVersionSha: draft.sourceVersionSha,
                importedAt: iso.string(from: draft.importedAt),
                snapshotFile: snapshotFile))
        }

        let archiveVersions = try versions.map { version -> ArchiveVersion in
            guard let origin = VersionOrigin(rawValue: version.origin.rawValue) else {
                throw ExportError.unsupportedVersionOrigin(version.origin.rawValue)
            }
            _ = origin
            return ArchiveVersion(
                id: version.id.uuidString, draftId: version.draftId.uuidString,
                content: version.content, origin: version.origin.rawValue,
                createdAt: iso.string(from: version.createdAt))
        }
        let archiveRelations = try relations.map { relation -> ArchiveRelation in
            guard RelationType(rawValue: relation.type.rawValue) != nil else {
                throw ExportError.unsupportedRelationType(relation.type.rawValue)
            }
            return ArchiveRelation(
                id: relation.id.uuidString,
                sourceDraftId: relation.sourceDraftId.uuidString,
                targetDraftId: relation.targetDraftId.uuidString,
                type: relation.type.rawValue, note: relation.note,
                createdAt: iso.string(from: relation.createdAt))
        }
        let archiveProjects = try projects.map { project -> ArchiveProject in
            guard ProjectStatus(rawValue: project.status.rawValue) != nil else {
                throw ExportError.unsupportedProjectStatus(project.status.rawValue)
            }
            return ArchiveProject(
                id: project.id.uuidString, name: project.name, notes: project.notes,
                status: project.status.rawValue, createdAt: iso.string(from: project.createdAt))
        }
        let archiveTags = ArchiveTags(
            tags: tags.map { ArchiveTag(id: $0.id.uuidString, name: $0.name) },
            memberships: projectTags.map {
                ArchiveProjectTag(projectId: $0.projectId.uuidString, tagId: $0.tagId.uuidString)
            })
        let archiveMemberships = memberships.map {
            ArchiveMembership(projectId: $0.projectId.uuidString, draftId: $0.draftId.uuidString)
        }
        let archiveDecisions = try decisions.map { pair -> ArchiveCandidateDecision in
            guard CandidateStatus(rawValue: pair.status.rawValue) != nil else {
                throw ExportError.unsupportedCandidateStatus(pair.status.rawValue)
            }
            return ArchiveCandidateDecision(
                id: pair.id.uuidString, draftA: pair.draftA.uuidString, draftB: pair.draftB.uuidString,
                kind: pair.kind.rawValue, status: pair.status.rawValue,
                fingerprintA: pair.fingerprintA, fingerprintB: pair.fingerprintB,
                lastDecision: pair.lastDecision, createdAt: iso.string(from: pair.createdAt),
                decidedAt: pair.decidedAt.map { iso.string(from: $0) })
        }
        let archiveSuggestions = suggestions.map { suggestion in
            ArchiveRemoteSuggestion(
                id: suggestion.id.uuidString, provider: suggestion.provider,
                model: suggestion.model,
                draftIds: (try? JSONDecoder().decode([UUID].self, from: suggestion.draftIdsData ?? Data()))?
                    .map(\.uuidString) ?? [],
                explanation: suggestion.explanation,
                citations: (try? JSONDecoder().decode([RemoteCitation].self, from: suggestion.citationsData ?? Data()))?
                    .map { ArchiveCitation(draftId: $0.draftId.uuidString, quote: $0.quote) },
                notice: suggestion.notice,
                createdAt: iso.string(from: suggestion.createdAt),
                dismissed: suggestion.dismissed)
        }

        let counts = Counts(
            drafts: archiveDrafts.count,
            versions: archiveVersions.count,
            projects: archiveProjects.count,
            memberships: archiveMemberships.count,
            relations: archiveRelations.count,
            tags: archiveTags.tags.count,
            projectTags: archiveTags.memberships.count,
            candidateDecisions: archiveDecisions.count,
            remoteSuggestions: archiveSuggestions.count,
            pdfSnapshots: pdfEntries.count)

        // 3. 写 ZIP（临时文件 → 原子改名，失败不落半成品）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var zip = MinimalZipWriter()
        func addJSON<T: Encodable>(_ value: T, path: String) throws {
            zip.addEntry(path: path, data: try encoder.encode(value))
        }
        try addJSON(archiveDrafts, path: "data/drafts.json")
        try addJSON(archiveVersions, path: "data/versions.json")
        try addJSON(archiveRelations, path: "data/relations.json")
        try addJSON(archiveProjects, path: "data/projects.json")
        try addJSON(archiveTags, path: "data/tags.json")
        try addJSON(archiveMemberships, path: "data/memberships.json")
        try addJSON(archiveDecisions, path: "data/candidates.json")
        try addJSON(archiveSuggestions, path: "data/remoteSuggestions.json")

        var fileRecords: [ManifestFile] = []
        for (path, data) in zip.stagedEntries {
            fileRecords.append(ManifestFile(
                path: path, sizeBytes: data.count, sha256: Self.sha256Hex(data)))
        }
        for pdf in pdfEntries {
            let data = try Data(contentsOf: pdf.sourceURL)
            zip.addEntry(path: pdf.entryPath, data: data)
            fileRecords.append(ManifestFile(
                path: pdf.entryPath, sizeBytes: data.count, sha256: Self.sha256Hex(data)))
        }

        let manifest = Manifest(
            formatVersion: 1, application: "DraftZero",
            exportedByVersion: appVersion,
            exportedAt: iso.string(from: Date()),
            files: fileRecords.sorted { $0.path < $1.path },
            counts: counts)
        try addJSON(manifest, path: "manifest.json")

        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".dzarchive-tmp-\(UUID().uuidString)")
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let archiveData = try zip.finalize()
        try archiveData.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 最小 ZIP writer（store 法，零依赖）

/// 只写不压缩的 ZIP 生成器：TXT/JSON 本身很小，PDF 已是压缩格式；
/// store 法实现简单、可用 macOS 系统解压与 C# ZipFile 双端验证。
public struct MinimalZipWriter {
    public private(set) var stagedEntries: [(path: String, data: Data)] = []

    public init() {}

    public mutating func addEntry(path: String, data: Data) {
        precondition(!path.hasPrefix("/") && !path.contains(".."), "ZIP 条目必须是安全相对路径")
        stagedEntries.append((path, data))
    }

    public mutating func finalize() throws -> Data {
        var out = Data()
        var central = Data()
        for (path, data) in stagedEntries {
            let nameBytes = Data(path.utf8)
            let crc = Self.crc32(data)
            let localHeaderOffset = UInt32(out.count)
            // Local file header
            var header = Data()
            header.appendLE(UInt32(0x04034b50))
            header.appendLE(UInt16(20))        // version needed
            header.appendLE(UInt16(1 << 11))   // UTF-8 name flag
            header.appendLE(UInt16(0))         // method: store
            header.appendLE(UInt16(0)); header.appendLE(UInt16(0)) // mod time/date
            header.appendLE(crc)
            header.appendLE(UInt32(data.count)) // compressed
            header.appendLE(UInt32(data.count)) // uncompressed
            header.appendLE(UInt16(nameBytes.count))
            header.appendLE(UInt16(0))          // extra len
            header.append(nameBytes)
            out.append(header)
            out.append(data)

            // Central directory record
            var cd = Data()
            cd.appendLE(UInt32(0x02014b50))
            cd.appendLE(UInt16(20))  // version made by
            cd.appendLE(UInt16(20))  // version needed
            cd.appendLE(UInt16(1 << 11))
            cd.appendLE(UInt16(0))   // method store
            cd.appendLE(UInt16(0)); cd.appendLE(UInt16(0))
            cd.appendLE(crc)
            cd.appendLE(UInt32(data.count))
            cd.appendLE(UInt32(data.count))
            cd.appendLE(UInt16(nameBytes.count))
            cd.appendLE(UInt16(0)); cd.appendLE(UInt16(0)) // extra/comment len
            cd.appendLE(UInt16(0))   // disk number
            cd.appendLE(UInt16(0))   // internal attrs
            cd.appendLE(UInt32(0))   // external attrs
            cd.appendLE(localHeaderOffset)
            cd.append(nameBytes)
            central.append(cd)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(stagedEntries.count))
        eocd.appendLE(UInt16(stagedEntries.count))
        eocd.appendLE(UInt32(central.count))
        eocd.appendLE(centralOffset)
        eocd.appendLE(UInt16(0))
        out.append(eocd)
        return out
    }

    /// 标准 CRC-32（IEEE 802.3，zip 规范）。
    public static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8(value >> 24))
    }
}
