using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

/// <summary>草稿与版本查询/写入（对齐 Mac DraftStore.swift）。</summary>
public static class DraftStore
{
    private static Draft ReadDraft(Dictionary<string, object?> r) => new()
    {
        Id = Db.Uid(Db.Str(r, "id")!),
        Title = Db.Str(r, "title") ?? "",
        Content = Db.Str(r, "content"),
        IsEditable = Db.Int(r, "isEditable") != 0,
        HasExtractableText = Db.Int(r, "hasExtractableText") != 0,
        SourceType = SourceTypeExtensions.FromDb(Db.Str(r, "sourceType")!),
        SourceLocation = Db.Str(r, "sourceLocation"),
        SourceLabel = Db.Str(r, "sourceLabel"),
        SnapshotFileURL = Db.Str(r, "snapshotFileURL"),
        Fingerprint = Db.Str(r, "fingerprint"),
        SourceVersionSha = Db.Str(r, "sourceVersionSha"),
        ImportedAt = Db.ParseTime(Db.Str(r, "importedAt")) ?? DateTime.UtcNow,
    };

    public static async Task<List<Draft>> DraftsAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM draft ORDER BY importedAt DESC");
            return Task.FromResult(rows.Select(ReadDraft).ToList());
        }).ConfigureAwait(false);

    public static async Task<Draft?> DraftAsync(this AppDatabase db, Guid id) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", Db.Uid(id)));
            return Task.FromResult(rows.Count == 0 ? null : ReadDraft(rows[0]));
        }).ConfigureAwait(false);

    /// <summary>重复来源检测：同一路径或同一归一化指纹都算已有快照。</summary>
    public static async Task<Draft?> FindExistingDraftAsync(this AppDatabase db, string? sourceLocation, string? fingerprint) =>
        await db.WriteAsync(conn =>
        {
            if (!string.IsNullOrEmpty(sourceLocation))
            {
                var rows = Db.ReadRows(conn, "SELECT * FROM draft WHERE sourceLocation=@loc LIMIT 1",
                    Db.P("@loc", sourceLocation));
                if (rows.Count > 0) return Task.FromResult<Draft?>(ReadDraft(rows[0]));
            }
            if (!string.IsNullOrEmpty(fingerprint))
            {
                var rows = Db.ReadRows(conn, "SELECT * FROM draft WHERE fingerprint=@fp LIMIT 1",
                    Db.P("@fp", fingerprint));
                if (rows.Count > 0) return Task.FromResult<Draft?>(ReadDraft(rows[0]));
            }
            return Task.FromResult<Draft?>(null);
        }).ConfigureAwait(false);

    /// <summary>插入草稿（initialVersion 时写入 initial 版本）。调用方需已完成重复检测。</summary>
    public static Task InsertDraftAsync(this AppDatabase db, Draft draft, bool initialVersion) =>
        db.WriteAsync(conn =>
        {
            using var tx = conn.BeginTransaction();
            Db.Exec(conn, """
                INSERT INTO draft (id,title,content,isEditable,hasExtractableText,sourceType,sourceLocation,sourceLabel,snapshotFileURL,fingerprint,sourceVersionSha,importedAt)
                VALUES (@id,@title,@content,@isEditable,@hasText,@sourceType,@sourceLocation,@sourceLabel,@snapshot,@fp,@vsha,@importedAt)
                """,
                Db.P("@id", Db.Uid(draft.Id)),
                Db.P("@title", draft.Title),
                Db.P("@content", draft.Content),
                Db.P("@isEditable", draft.IsEditable ? 1L : 0L),
                Db.P("@hasText", draft.HasExtractableText ? 1L : 0L),
                Db.P("@sourceType", draft.SourceType.DbValue()),
                Db.P("@sourceLocation", draft.SourceLocation),
                Db.P("@sourceLabel", draft.SourceLabel),
                Db.P("@snapshot", draft.SnapshotFileURL),
                Db.P("@fp", draft.Fingerprint),
                Db.P("@vsha", draft.SourceVersionSha),
                Db.P("@importedAt", Db.Fmt(draft.ImportedAt)));
            if (initialVersion && draft.Content is not null)
            {
                InsertVersion(conn, new DraftVersion
                {
                    DraftId = draft.Id,
                    Content = draft.Content,
                    Origin = VersionOrigin.Initial,
                });
            }
            DraftSearchStore.Upsert(conn, draft);
            tx.Commit();
            return Task.CompletedTask;
        });

    /// <summary>应用内新建文本草稿（R-001）。</summary>
    public static async Task<Draft> CreateManualDraftAsync(this AppDatabase db, string title, string content)
    {
        var draft = new Draft
        {
            Title = string.IsNullOrWhiteSpace(title) ? "未命名草稿" : title,
            Content = content,
            IsEditable = true,
            SourceType = SourceType.Manual,
        };
        await db.InsertDraftAsync(draft, initialVersion: true).ConfigureAwait(false);
        return draft;
    }

    public static async Task UpdateDraftContentAsync(this AppDatabase db, Guid id, string content) =>
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE draft SET content=@c WHERE id=@id",
                Db.P("@c", content), Db.P("@id", Db.Uid(id)));
            UpsertSearchRow(conn, Db.Uid(id));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    public static async Task UpdateDraftTitleAsync(this AppDatabase db, Guid id, string title) =>
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE draft SET title=@t WHERE id=@id",
                Db.P("@t", title), Db.P("@id", Db.Uid(id)));
            UpsertSearchRow(conn, Db.Uid(id));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    /// <summary>删除草稿（R-011）：正文与版本级联移除；演化关系行保留。</summary>
    public static async Task DeleteDraftAsync(this AppDatabase db, Guid id) =>
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "DELETE FROM projectDraft WHERE draftId=@id", Db.P("@id", Db.Uid(id)));
            Db.Exec(conn, "DELETE FROM draft WHERE id=@id", Db.P("@id", Db.Uid(id)));
            DraftSearchStore.Remove(conn, id);
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    // ---- 版本（R-006） ----

    public static async Task<List<DraftVersion>> VersionsAsync(this AppDatabase db, Guid draftId) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT * FROM draftVersion WHERE draftId=@id ORDER BY createdAt DESC, rowid DESC
                """, Db.P("@id", Db.Uid(draftId)));
            return Task.FromResult(rows.Select(r => new DraftVersion
            {
                Id = Db.Uid(Db.Str(r, "id")!),
                DraftId = Db.Uid(Db.Str(r, "draftId")!),
                Content = Db.Str(r, "content") ?? "",
                Origin = VersionOriginExtensions.FromDb(Db.Str(r, "origin")!),
                CreatedAt = Db.ParseTime(Db.Str(r, "createdAt")) ?? DateTime.UtcNow,
            }).ToList());
        }).ConfigureAwait(false);

    /// <summary>每份草稿最近一次版本时间（"最近编辑"排序用）。</summary>
    public static async Task<Dictionary<Guid, DateTime>> LastEditedByDraftAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT draftId, MAX(createdAt) AS latest FROM draftVersion GROUP BY draftId");
            var result = new Dictionary<Guid, DateTime>();
            foreach (var r in rows)
            {
                if (Db.Str(r, "draftId") is { } idStr && Db.ParseTime(Db.Str(r, "latest")) is { } t)
                {
                    result[Db.Uid(idStr)] = t;
                }
            }
            return Task.FromResult(result);
        }).ConfigureAwait(false);

    private static void InsertVersion(SqliteConnection conn, DraftVersion version)
    {
        Db.Exec(conn, """
            INSERT INTO draftVersion (id,draftId,content,origin,createdAt)
            VALUES (@id,@draftId,@content,@origin,@createdAt)
            """,
            Db.P("@id", Db.Uid(version.Id)),
            Db.P("@draftId", Db.Uid(version.DraftId)),
            Db.P("@content", version.Content),
            Db.P("@origin", version.Origin.DbValue()),
            Db.P("@createdAt", Db.Fmt(version.CreatedAt)));
    }

    /// <summary>无实际文本变化不产生重复版本（R-006 验收）。</summary>
    public static Task RecordVersionIfChangedAsync(this AppDatabase db, Guid draftId, string content, VersionOrigin origin) =>
        db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT content FROM draftVersion WHERE draftId=@id ORDER BY createdAt DESC, rowid DESC LIMIT 1
                """, Db.P("@id", Db.Uid(draftId)));
            var last = rows.Count > 0 ? Db.Str(rows[0], "content") : null;
            if (last == content) return Task.CompletedTask;
            InsertVersion(conn, new DraftVersion { DraftId = draftId, Content = content, Origin = origin });
            return Task.CompletedTask;
        });

    /// <summary>恢复旧版：产生 origin=Restore 的新版本，不抹掉中间历史（R-006）。</summary>
    public static async Task<Draft?> RestoreVersionAsync(this AppDatabase db, Guid versionId) =>
        await db.WriteAsync(conn =>
        {
            using var tx = conn.BeginTransaction();
            var rows = Db.ReadRows(conn, "SELECT * FROM draftVersion WHERE id=@id", Db.P("@id", Db.Uid(versionId)));
            if (rows.Count == 0) return Task.FromResult<Draft?>(null);
            var version = rows[0];
            var draftId = Db.Uid(Db.Str(version, "draftId")!);
            var content = Db.Str(version, "content") ?? "";
            Db.Exec(conn, "UPDATE draft SET content=@c WHERE id=@id",
                Db.P("@c", content), Db.P("@id", draftId));
            InsertVersion(conn, new DraftVersion
            {
                DraftId = draftId,
                Content = content,
                Origin = VersionOrigin.Restore,
            });
            UpsertSearchRow(conn, Db.Uid(draftId));
            tx.Commit();
            var draftRows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", draftId));
            return Task.FromResult(draftRows.Count == 0 ? null : ReadDraft(draftRows[0]));
        }).ConfigureAwait(false);

    // ---- 演化关系（R-003/R-007） ----

    /// <summary>从只读快照或既有草稿衍生新的可编辑草稿，保留"源自"关系（R-003）。</summary>
    public static async Task<Draft?> CreateDerivedDraftAsync(this AppDatabase db, Guid sourceDraftId, string? title, string content) =>
        await db.WriteAsync(conn =>
        {
            var srcRows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", Db.Uid(sourceDraftId)));
            if (srcRows.Count == 0) return Task.FromResult<Draft?>(null);
            var source = ReadDraft(srcRows[0]);
            var draft = new Draft
            {
                Title = title ?? source.Title + "（副本）",
                Content = content,
                IsEditable = true,
                SourceType = SourceType.Derived,
            };
            InsertDraftRow(conn, draft);
            InsertVersion(conn, new DraftVersion { DraftId = draft.Id, Content = content, Origin = VersionOrigin.Initial });
            Db.Exec(conn, """
                INSERT INTO evolutionRelation (id,sourceDraftId,targetDraftId,type,note,createdAt)
                VALUES (@id,@src,@dst,@type,NULL,@createdAt)
                """,
                Db.P("@id", Db.Uid(Guid.NewGuid())),
                Db.P("@src", Db.Uid(source.Id)),
                Db.P("@dst", Db.Uid(draft.Id)),
                Db.P("@type", RelationType.Derived.DbValue()),
                Db.P("@createdAt", Db.Fmt(DateTime.UtcNow)));
            return Task.FromResult<Draft?>(draft);
        }).ConfigureAwait(false);

    /// <summary>按 ID 重读草稿并刷新搜索行（衍生/拆分/合并/恢复路径用）。</summary>
    private static void UpsertSearchRow(SqliteConnection conn, string draftId)
    {
        var rows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", draftId));
        if (rows.Count > 0) DraftSearchStore.Upsert(conn, ReadDraft(rows[0]));
    }

    private static void InsertDraftRow(SqliteConnection conn, Draft draft)
    {
        Db.Exec(conn, """
            INSERT INTO draft (id,title,content,isEditable,hasExtractableText,sourceType,sourceLocation,sourceLabel,snapshotFileURL,fingerprint,sourceVersionSha,importedAt)
            VALUES (@id,@title,@content,@isEditable,@hasText,@sourceType,@sourceLocation,@sourceLabel,@snapshot,@fp,@vsha,@importedAt)
            """,
            Db.P("@id", Db.Uid(draft.Id)),
            Db.P("@title", draft.Title),
            Db.P("@content", draft.Content),
            Db.P("@isEditable", draft.IsEditable ? 1L : 0L),
            Db.P("@hasText", draft.HasExtractableText ? 1L : 0L),
            Db.P("@sourceType", draft.SourceType.DbValue()),
            Db.P("@sourceLocation", draft.SourceLocation),
            Db.P("@sourceLabel", draft.SourceLabel),
            Db.P("@snapshot", draft.SnapshotFileURL),
            Db.P("@fp", draft.Fingerprint),
            Db.P("@vsha", draft.SourceVersionSha),
            Db.P("@importedAt", Db.Fmt(draft.ImportedAt)));
        DraftSearchStore.Upsert(conn, draft);
    }

    /// <summary>拆分（R-007）：一段文字生成为新草稿；源草稿内容不变，双向可追溯。</summary>
    public static async Task<Draft?> SplitDraftAsync(this AppDatabase db, Guid sourceId, string piece, int offsetInSource, string? newTitle) =>
        await db.WriteAsync(conn =>
        {
            var srcRows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", Db.Uid(sourceId)));
            if (srcRows.Count == 0) return Task.FromResult<Draft?>(null);
            var source = ReadDraft(srcRows[0]);
            var trimmed = piece.Trim();
            if (trimmed.Length == 0) return Task.FromResult<Draft?>(null);
            var draft = new Draft
            {
                Title = newTitle ?? TextReading.ExtractTitle(trimmed, source.Title + "（拆分）"),
                Content = trimmed,
                IsEditable = true,
                SourceType = SourceType.Derived,
            };
            InsertDraftRow(conn, draft);
            InsertVersion(conn, new DraftVersion { DraftId = draft.Id, Content = trimmed, Origin = VersionOrigin.Initial });
            Db.Exec(conn, """
                INSERT INTO evolutionRelation (id,sourceDraftId,targetDraftId,type,note,createdAt)
                VALUES (@id,@src,@dst,@type,@note,@createdAt)
                """,
                Db.P("@id", Db.Uid(Guid.NewGuid())),
                Db.P("@src", Db.Uid(source.Id)),
                Db.P("@dst", Db.Uid(draft.Id)),
                Db.P("@type", RelationType.Split.DbValue()),
                Db.P("@note", $"拆分自第 {offsetInSource} 字符处"),
                Db.P("@createdAt", Db.Fmt(DateTime.UtcNow)));
            return Task.FromResult<Draft?>(draft);
        }).ConfigureAwait(false);

    /// <summary>合并（R-007）：两份及以上按指定顺序合成新草稿；来源不变。</summary>
    public static async Task<Draft?> MergeDraftsAsync(this AppDatabase db, IReadOnlyList<Guid> ids, string? title)
    {
        if (ids.Count < 2) return null;
        return await db.WriteAsync(conn =>
        {
            var sources = new List<Draft>();
            foreach (var id in ids)
            {
                var rows = Db.ReadRows(conn, "SELECT * FROM draft WHERE id=@id", Db.P("@id", Db.Uid(id)));
                if (rows.Count == 0) return Task.FromResult<Draft?>(null);
                sources.Add(ReadDraft(rows[0]));
            }
            var joined = string.Join("\n\n", sources.Select(s => s.Content ?? ""));
            var draft = new Draft
            {
                Title = title ?? "合并：" + string.Concat(sources[0].Title.Take(12)) + " 等",
                Content = joined,
                IsEditable = true,
                SourceType = SourceType.Derived,
            };
            using var tx = conn.BeginTransaction();
            InsertDraftRow(conn, draft);
            InsertVersion(conn, new DraftVersion { DraftId = draft.Id, Content = joined, Origin = VersionOrigin.Merge });
            foreach (var source in sources)
            {
                Db.Exec(conn, """
                    INSERT INTO evolutionRelation (id,sourceDraftId,targetDraftId,type,note,createdAt)
                    VALUES (@id,@src,@dst,@type,NULL,@createdAt)
                    """,
                    Db.P("@id", Db.Uid(Guid.NewGuid())),
                    Db.P("@src", Db.Uid(source.Id)),
                    Db.P("@dst", Db.Uid(draft.Id)),
                    Db.P("@type", RelationType.Merge.DbValue()),
                    Db.P("@createdAt", Db.Fmt(DateTime.UtcNow)));
            }
            tx.Commit();
            return Task.FromResult<Draft?>(draft);
        }).ConfigureAwait(false);
    }

    public static async Task<List<EvolutionRelation>> RelationsAsync(this AppDatabase db, Guid draftId) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT * FROM evolutionRelation WHERE sourceDraftId=@id OR targetDraftId=@id ORDER BY createdAt DESC
                """, Db.P("@id", Db.Uid(draftId)));
            return Task.FromResult(rows.Select(ReadRelation).ToList());
        }).ConfigureAwait(false);

    private static EvolutionRelation ReadRelation(Dictionary<string, object?> r) => new()
    {
        Id = Db.Uid(Db.Str(r, "id")!),
        SourceDraftId = Db.Uid(Db.Str(r, "sourceDraftId")!),
        TargetDraftId = Db.Uid(Db.Str(r, "targetDraftId")!),
        Type = RelationTypeExtensions.FromDb(Db.Str(r, "type")!),
        Note = Db.Str(r, "note"),
        CreatedAt = Db.ParseTime(Db.Str(r, "createdAt")) ?? DateTime.UtcNow,
    };

    /// <summary>关系说明可修改或移除（R-007 验收）。</summary>
    public static async Task UpdateRelationNoteAsync(this AppDatabase db, Guid id, string? note) =>
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE evolutionRelation SET note=@note WHERE id=@id",
                Db.P("@note", note), Db.P("@id", Db.Uid(id)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    /// <summary>某草稿是否存在（供导入来路等校验）。</summary>
    public static async Task<bool> DraftExistsAsync(this AppDatabase db, Guid id) =>
        await db.WriteAsync(conn =>
            Task.FromResult(Db.Long(conn, "SELECT count(*) FROM draft WHERE id=@id",
                Db.P("@id", Db.Uid(id))) > 0)).ConfigureAwait(false);
}
