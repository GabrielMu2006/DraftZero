import Foundation
import GRDB

/// 可重建的检索索引（SPEC §3"切片与索引"）：切片、向量、增量更新全部存本机库。
/// 索引损坏可从草稿正文完全重建，不影响用户确认的项目归属（R-004）。
extension AppDatabase {

    public func refreshSemanticIndex(drafts: [Draft], embedder: TextEmbedding) async throws {
        try await pool.write { db in
            // 删除已不存在草稿的索引行（外键级联亦兜底）。
            let keep = Set(drafts.map(\.id))
            let stale = try IndexStatus.fetchAll(db).map(\.draftId).filter { !keep.contains($0) }
            for id in stale {
                _ = try IndexChunk.filter(Column("draftId") == id).deleteAll(db)
                _ = try IndexStatus.filter(Column("draftId") == id).deleteAll(db)
            }
        }

        for draft in drafts {
            guard let content = draft.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let fingerprint = TextReading.fingerprint(of: content)
            let existing = try await pool.read { db in
                try IndexStatus.fetchOne(db, key: draft.id)
            }
            // 指纹（内容）或模型签名（向量器版本）任一变化都重嵌：
            // 2026-10 换栈（CoreML→ONNX + 补 "query: " 前缀）后旧向量与新向量不可混用。
            if let existing, existing.fingerprint == fingerprint,
               existing.modelSignature == embedder.signature {
                continue // 内容与向量器均未变，跳过（增量索引）
            }

            let chunks = Chunker.chunk(content)
            let embeddings = try embedder.embed(chunks.map(\.text))
            try await pool.write { db in
                _ = try IndexChunk.filter(Column("draftId") == draft.id).deleteAll(db)
                _ = try IndexStatus.filter(Column("draftId") == draft.id).deleteAll(db)
                for (chunk, vector) in zip(chunks, embeddings) {
                    let row = IndexChunk(
                        draftId: draft.id,
                        chunkIndex: chunk.chunkIndex,
                        text: chunk.text,
                        startOffset: chunk.startOffset,
                        heading: chunk.heading,
                        embedding: Data(bytes: vector, count: vector.count * MemoryLayout<Float>.size))
                    try row.insert(db)
                }
                let status = IndexStatus(
                    draftId: draft.id, fingerprint: fingerprint, indexedAt: Date(),
                    modelSignature: embedder.signature)
                try status.insert(db)
            }
        }
    }

    /// 全部草稿的索引切片（含向量与来源位置），供候选引擎计算文档对相似度。
    public func chunksByDraft() async throws -> [UUID: [IndexChunk]] {
        try await pool.read { db in
            let rows = try IndexChunk.fetchAll(db)
            var result: [UUID: [IndexChunk]] = [:]
            for row in rows {
                result[row.draftId, default: []].append(row)
            }
            return result.mapValues { $0.sorted { $0.chunkIndex < $1.chunkIndex } }
        }
    }

    public func indexStatuses() async throws -> [IndexStatus] {
        try await pool.read { db in
            try IndexStatus.fetchAll(db)
        }
    }

    /// 完全重建：清空索引后重新切片与向量化（R-004"故障后可重建索引"）。
    public func rebuildSemanticIndex(drafts: [Draft], embedder: TextEmbedding) async throws {
        try await pool.write { db in
            _ = try IndexChunk.deleteAll(db)
            _ = try IndexStatus.deleteAll(db)
        }
        try await refreshSemanticIndex(drafts: drafts, embedder: embedder)
    }
}

/// 索引切片行。表是可重建数据，不含任何用户确认的归属。
public struct IndexChunk: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var draftId: UUID
    public var chunkIndex: Int
    public var text: String
    public var startOffset: Int
    public var heading: String?
    public var embedding: Data

    public static let databaseTableName = "indexChunk"

    public init(draftId: UUID, chunkIndex: Int, text: String, startOffset: Int, heading: String?, embedding: Data) {
        self.draftId = draftId
        self.chunkIndex = chunkIndex
        self.text = text
        self.startOffset = startOffset
        self.heading = heading
        self.embedding = embedding
    }

    public var vector: [Float] {
        embedding.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

public struct IndexStatus: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var draftId: UUID
    public var fingerprint: String
    public var indexedAt: Date
    /// 嵌入此切片的向量器签名（v5 迁移新增；旧行为空串，刷新时自动重嵌）。
    public var modelSignature: String

    public static let databaseTableName = "indexStatus"

    public init(draftId: UUID, fingerprint: String, indexedAt: Date, modelSignature: String) {
        self.draftId = draftId
        self.fingerprint = fingerprint
        self.indexedAt = indexedAt
        self.modelSignature = modelSignature
    }
}
