import Foundation
import GRDB

/// Windows 导出档案 → Mac 空工作区一次性导入（D-002 双向迁移）。
/// 仅允许空库；全部行写入单个 GRDB 事务（原子，失败零部分写入）；
/// PDF 快照先落位 snapshots/dz-<文件名>（事务失败时清理），
/// 库行内保存最终绝对路径（路径重绑）。导入后由应用重建语义索引。
public enum DzArchiveImporter {

    public struct ImportCounts {
        public var drafts: Int
        public var versions: Int
        public var projects: Int
        public var memberships: Int
        public var relations: Int
        public var tags: Int
        public var projectTags: Int
        public var candidateDecisions: Int
        public var remoteSuggestions: Int
        public var pdfSnapshots: Int
    }

    public enum ImportError: LocalizedError {
        case workspaceNotEmpty
        case idCollision(String)

        public var errorDescription: String? {
            switch self {
            case .workspaceNotEmpty:
                "当前 Mac 工作区已有内容。迁移仅支持导入到空工作区；请先备份或另建空工作区（不做自动合并）。"
            case .idCollision(let id):
                "导入的记录与当前工作区冲突：\(id)"
            }
        }
    }

    public static func isWorkspaceEmpty(_ database: AppDatabase) async throws -> Bool {
        try await database.pool.read { db in
            let n = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM draft) + (SELECT count(*) FROM project) +
                       (SELECT count(*) FROM candidatePair) + (SELECT count(*) FROM remoteSuggestion)
                """)
            return n == 0
        }
    }

    /// - Parameters:
    ///   - database: 目标（空）工作区库。导入成功后需由调用方重建语义索引。
    ///   - snapshotsDirectory: PDF 快照最终目录（Mac 端 workspace.snapshots）。
    public static func importArchive(archivePath: String, into database: AppDatabase,
                                     snapshotsDirectory: URL) async throws -> ImportCounts {
        guard try await isWorkspaceEmpty(database) else {
            throw ImportError.workspaceNotEmpty
        }

        let contents = try DzArchiveReader.read(archivePath: archivePath)

        // PDF 先落位（事务前），事务失败时清理。
        let staged: [(entry: String, finalURL: URL)] = contents.pdfFiles
            .map { (entry, url) in
                (entry, snapshotsDirectory.appendingPathComponent("dz-" + url.lastPathComponent))
            }
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        for (entry, finalURL) in staged {
            let source = contents.pdfFiles[entry]!
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.copyItem(at: source, to: finalURL)
        }

        let date: @Sendable (String) -> Date = { s in
            let formatter = ISO8601DateFormatter()
            return (try? formatter.date(from: s)) ?? Date(timeIntervalSince1970: 0)
        }

        defer {
            try? FileManager.default.removeItem(at: contents.extractedDirectory)
        }
        do {
            try await database.pool.write { db in
                for d in contents.drafts {
                    var draft = Draft(
                        id: UUID(uuidString: d.id)!, title: d.title, content: d.content,
                        isEditable: d.isEditable, hasExtractableText: d.hasExtractableText,
                        sourceType: SourceType(rawValue: d.sourceType) ?? .manual,
                        sourceLocation: d.sourceLocation, sourceLabel: d.sourceLabel,
                        snapshotFileURL: d.snapshotFile.map { snapshotsDirectory.appendingPathComponent("dz-" + ($0 as NSString).lastPathComponent).path },
                        fingerprint: d.fingerprint, sourceVersionSha: d.sourceVersionSha,
                        importedAt: date(d.importedAt))
                    try draft.insert(db)
                }
                for v in contents.versions {
                    var version = DraftVersion(
                        id: UUID(uuidString: v.id)!, draftId: UUID(uuidString: v.draftId)!,
                        content: v.content,
                        origin: VersionOrigin(rawValue: v.origin) ?? .initial,
                        createdAt: date(v.createdAt))
                    try version.insert(db)
                }
                for r in contents.relations {
                    var relation = EvolutionRelation(
                        id: UUID(uuidString: r.id)!,
                        sourceDraftId: UUID(uuidString: r.sourceDraftId)!,
                        targetDraftId: UUID(uuidString: r.targetDraftId)!,
                        type: RelationType(rawValue: r.type) ?? .manualLink,
                        note: r.note, createdAt: date(r.createdAt))
                    try relation.insert(db)
                }
                for p in contents.projects {
                    var project = Project(
                        id: UUID(uuidString: p.id)!, name: p.name, notes: p.notes,
                        status: ProjectStatus(rawValue: p.status) ?? .inbox,
                        createdAt: date(p.createdAt))
                    try project.insert(db)
                }
                for t in contents.tags.tags {
                    var tag = Tag(id: UUID(uuidString: t.id)!, name: t.name)
                    try tag.insert(db)
                }
                for m in contents.tags.memberships {
                    try db.execute(sql: "INSERT INTO projectTag (projectId, tagId) VALUES (?, ?)",
                                   arguments: [UUID(uuidString: m.projectId)!, UUID(uuidString: m.tagId)!])
                }
                for m in contents.memberships {
                    try db.execute(sql: "INSERT INTO projectDraft (projectId, draftId) VALUES (?, ?)",
                                   arguments: [UUID(uuidString: m.projectId)!, UUID(uuidString: m.draftId)!])
                }
                for c in contents.decisions {
                    var pair = CandidatePair(
                        id: UUID(uuidString: c.id)!,
                        draftA: UUID(uuidString: c.draftA)!, draftB: UUID(uuidString: c.draftB)!,
                        kind: CandidateKind(rawValue: c.kind) ?? .lead, score: 0,
                        evidence: nil, status: CandidateStatus(rawValue: c.status) ?? .rejected,
                        fingerprintA: c.fingerprintA, fingerprintB: c.fingerprintB,
                        lastDecision: c.lastDecision, createdAt: date(c.createdAt),
                        decidedAt: c.decidedAt.flatMap { date($0) })
                    try pair.insert(db)
                }
                for sv in contents.suggestions {
                    let draftIdUUIDs = sv.draftIds.compactMap(UUID.init(uuidString:))
                    let citations = (sv.citations ?? []).compactMap { c -> RemoteCitation? in
                        guard let uid = UUID(uuidString: c.draftId) else { return nil }
                        return RemoteCitation(draftId: uid, quote: c.quote)
                    }
                    var suggestion = RemoteSuggestion(
                        id: UUID(uuidString: sv.id)!, provider: sv.provider, model: sv.model,
                        draftIdsData: try? JSONEncoder().encode(draftIdUUIDs),
                        explanation: sv.explanation,
                        citationsData: try? JSONEncoder().encode(citations),
                        notice: sv.notice, createdAt: date(sv.createdAt), dismissed: sv.dismissed)
                    try suggestion.insert(db)
                }
            }
        } catch {
            // 事务已回滚；清理已落位的 PDF，保持零部分写入。
            for (_, finalURL) in staged {
                try? FileManager.default.removeItem(at: finalURL)
            }
            throw error
        }

        return ImportCounts(
            drafts: contents.drafts.count, versions: contents.versions.count,
            projects: contents.projects.count,
            memberships: contents.memberships.count, relations: contents.relations.count,
            tags: contents.tags.tags.count, projectTags: contents.tags.memberships.count,
            candidateDecisions: contents.decisions.count,
            remoteSuggestions: contents.suggestions.count,
            pdfSnapshots: contents.pdfFiles.count)
    }
}
