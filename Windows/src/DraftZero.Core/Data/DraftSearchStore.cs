using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

/// <summary>
/// 草稿全文搜索索引（W-007）：SQLite FTS5 trigram。
/// trigram 对 ≥3 字查询走 MATCH；2 字中文等短查询用 LIKE 触发 trigram 索引加速
/// （SQLite ≥3.34 文档行为，bundled e_sqlite3 = 3.53.3 实测命中索引）。
/// 索引是可重建数据：打开库时计数不一致（含旧库/导入遗留）自动全量重建。
/// </summary>
public static class DraftSearchStore
{
    /// <summary>建表与一致性守卫（在 AppDatabase.Migrate 末尾调用）。</summary>
    public static void EnsureSchemaAndConsistency(SqliteConnection conn)
    {
        Db.Exec(conn, """
            CREATE VIRTUAL TABLE IF NOT EXISTS draftSearch USING fts5(
                title, content, draftId UNINDEXED, tokenize='trigram'
            );
            """);
        var draftCount = Db.Long(conn, "SELECT count(*) FROM draft") ?? 0;
        var searchCount = Db.Long(conn, "SELECT count(*) FROM draftSearch") ?? 0;
        if (draftCount != searchCount)
        {
            Rebuild(conn);
        }
    }

    /// <summary>单条 upsert（insert 或内容/标题变化时调用）。</summary>
    public static void Upsert(SqliteConnection conn, Draft draft)
    {
        Remove(conn, draft.Id);
        Db.Exec(conn, """
            INSERT INTO draftSearch (title, content, draftId) VALUES (@title, @content, @draftId)
            """,
            Db.P("@title", draft.Title),
            Db.P("@content", draft.Content ?? ""),
            Db.P("@draftId", Db.Uid(draft.Id)));
    }

    public static void Remove(SqliteConnection conn, Guid draftId)
    {
        Db.Exec(conn, "DELETE FROM draftSearch WHERE draftId=@id", Db.P("@id", Db.Uid(draftId)));
    }

    /// <summary>全量重建（从 draft 表），供一致性守卫与"重建索引"入口。</summary>
    public static void Rebuild(SqliteConnection conn)
    {
        Db.Exec(conn, "DELETE FROM draftSearch");
        Db.Exec(conn, """
            INSERT INTO draftSearch (title, content, draftId)
            SELECT title, COALESCE(content, ''), id FROM draft
            """);
    }

    /// <summary>
    /// 按关键词查草稿 ID（命中标题或正文，大小写不敏感；子串语义）。
    /// 空查询返回空表。返回按 importedAt 降序的 ID 列表（UI 按此排序展示）。
    /// </summary>
    public static async Task<List<Guid>> SearchAsync(AppDatabase db, string query)
    {
        var trimmed = (query ?? "").Trim();
        if (trimmed.Length == 0) return [];
        return await db.WriteAsync(conn =>
        {
            // LIKE 触发 trigram 索引加速；ESCAPE 兜住用户输入里的 % _ 通配符。
            var escaped = trimmed.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");
            var rows = Db.ReadRows(conn, """
                SELECT s.draftId AS draftId
                FROM draftSearch s JOIN draft d ON d.id = s.draftId
                WHERE s.title LIKE @p ESCAPE '\' OR s.content LIKE @p ESCAPE '\'
                ORDER BY d.importedAt DESC
                """, Db.P("@p", $"%{escaped}%"));
            var ids = new List<Guid>(rows.Count);
            foreach (var r in rows)
            {
                if (Db.Str(r, "draftId") is { } id) ids.Add(Db.Uid(id));
            }
            return Task.FromResult(ids);
        });
    }
}

/// <summary>AppDatabase 便捷入口。</summary>
public static class DraftSearchStoreExtensions
{
    public static Task<List<Guid>> SearchDraftsAsync(this AppDatabase db, string query) =>
        DraftSearchStore.SearchAsync(db, query);
}
