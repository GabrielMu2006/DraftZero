using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

/// <summary>
/// 可重建的检索索引（SPEC §3"切片与索引"）：切片、向量、增量更新全部存本机库。
/// 索引损坏可从草稿正文完全重建，不影响用户确认的项目归属（R-004）。
/// </summary>
public static class SemanticIndexStore
{
    public sealed record IndexChunkRow(Guid DraftId, int ChunkIndex, string Text, int StartOffset,
        string? Heading, float[] Vector);

    private sealed record PendingDraft(Guid DraftId, string Fingerprint, List<Chunker.Chunk> Chunks);

    /// <summary>增量索引：删除已不存在草稿的索引行；内容未变的草稿跳过。</summary>
    public static async Task RefreshSemanticIndexAsync(AppDatabase db, IReadOnlyList<Draft> drafts, ITextEmbedding embedder)
    {
        // 1.（锁内）清理已不存在草稿的索引行（外键级联亦兜底），并找需要重建的草稿。
        var pending = await db.WriteAsync(conn =>
        {
            var keep = drafts.Select(d => Db.Uid(d.Id)).ToHashSet();
            var stale = Db.ReadRows(conn, "SELECT draftId FROM indexStatus")
                .Select(r => Db.Str(r, "draftId")!)
                .Where(id => !keep.Contains(id))
                .ToList();
            foreach (var id in stale)
            {
                Db.Exec(conn, "DELETE FROM indexChunk WHERE draftId=@id", Db.P("@id", id));
                Db.Exec(conn, "DELETE FROM indexStatus WHERE draftId=@id", Db.P("@id", id));
            }

            var result = new List<PendingDraft>();
            foreach (var draft in drafts)
            {
                var content = draft.Content;
                if (content is null || string.IsNullOrWhiteSpace(content)) continue;
                var fingerprint = TextReading.Fingerprint(content);
                var existing = Db.ReadRows(conn, "SELECT fingerprint FROM indexStatus WHERE draftId=@id",
                    Db.P("@id", Db.Uid(draft.Id)));
                if (existing.Count > 0 && Db.Str(existing[0], "fingerprint") == fingerprint) continue;
                result.Add(new PendingDraft(draft.Id, fingerprint, Chunker.ChunkText(content)));
            }
            return Task.FromResult(result);
        }).ConfigureAwait(false);
        if (pending.Count == 0) return;

        // 2.（锁外）逐稿向量化后写库；嵌入可能较慢，不持有写锁。
        foreach (var item in pending)
        {
            var texts = item.Chunks.Select(c => c.Text).ToArray();
            var embeddings = embedder.Embed(texts);
            await db.WriteAsync(conn =>
            {
                using var tx = conn.BeginTransaction();
                Db.Exec(conn, "DELETE FROM indexChunk WHERE draftId=@id", Db.P("@id", Db.Uid(item.DraftId)));
                Db.Exec(conn, "DELETE FROM indexStatus WHERE draftId=@id", Db.P("@id", Db.Uid(item.DraftId)));
                for (int i = 0; i < item.Chunks.Count; i++)
                {
                    var chunk = item.Chunks[i];
                    Db.Exec(conn, """
                        INSERT INTO indexChunk (draftId,chunkIndex,text,startOffset,heading,embedding)
                        VALUES (@draftId,@chunkIndex,@text,@startOffset,@heading,@embedding)
                        """,
                        Db.P("@draftId", Db.Uid(item.DraftId)),
                        Db.P("@chunkIndex", chunk.ChunkIndex),
                        Db.P("@text", chunk.Text),
                        Db.P("@startOffset", chunk.StartOffset),
                        Db.P("@heading", chunk.Heading),
                        Db.P("@embedding", FloatsToBytes(embeddings[i])));
                }
                Db.Exec(conn, "INSERT INTO indexStatus (draftId,fingerprint,indexedAt) VALUES (@draftId,@fp,@at)",
                    Db.P("@draftId", Db.Uid(item.DraftId)),
                    Db.P("@fp", item.Fingerprint),
                    Db.P("@at", Db.Fmt(DateTime.UtcNow)));
                tx.Commit();
                return Task.CompletedTask;
            }).ConfigureAwait(false);
        }
    }

    /// <summary>完全重建：清空索引后重新切片与向量化（R-004"故障后可重建索引"）。</summary>
    public static async Task RebuildSemanticIndexAsync(AppDatabase db, IReadOnlyList<Draft> drafts, ITextEmbedding embedder)
    {
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "DELETE FROM indexChunk");
            Db.Exec(conn, "DELETE FROM indexStatus");
            return Task.CompletedTask;
        }).ConfigureAwait(false);
        await RefreshSemanticIndexAsync(db, drafts, embedder).ConfigureAwait(false);
    }

    /// <summary>全部草稿的索引切片（含向量与来源位置），供候选引擎计算文档对相似度。</summary>
    public static async Task<Dictionary<Guid, List<IndexChunkRow>>> ChunksByDraftAsync(AppDatabase db) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM indexChunk ORDER BY draftId, chunkIndex");
            var result = new Dictionary<Guid, List<IndexChunkRow>>();
            foreach (var r in rows)
            {
                var draftId = Db.Uid(Db.Str(r, "draftId")!);
                if (!result.TryGetValue(draftId, out var list)) result[draftId] = list = [];
                var embedding = (byte[])r["embedding"]!;
                list.Add(new IndexChunkRow(
                    draftId,
                    (int)Db.Int(r, "chunkIndex"),
                    Db.Str(r, "text") ?? "",
                    (int)Db.Int(r, "startOffset"),
                    Db.Str(r, "heading"),
                    BytesToFloats(embedding)));
            }
            return Task.FromResult(result);
        }).ConfigureAwait(false);

    public static async Task<int> IndexChunkCountAsync(AppDatabase db) =>
        (int)(await db.WriteAsync(conn =>
            Task.FromResult(Db.Long(conn, "SELECT count(*) FROM indexChunk") ?? 0)).ConfigureAwait(false));

    public static byte[] FloatsToBytes(float[] v)
    {
        var bytes = new byte[v.Length * sizeof(float)];
        Buffer.BlockCopy(v, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    public static float[] BytesToFloats(byte[] b)
    {
        var v = new float[b.Length / sizeof(float)];
        Buffer.BlockCopy(b, 0, v, 0, b.Length);
        return v;
    }
}
