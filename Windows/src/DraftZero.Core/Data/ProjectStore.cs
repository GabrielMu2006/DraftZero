using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

/// <summary>项目、标签与多项目归属（R-005/R-008）。对齐 Mac ProjectStore.swift。</summary>
public static class ProjectStore
{
    private static Project ReadProject(Dictionary<string, object?> r) => new()
    {
        Id = Db.Uid(Db.Str(r, "id")!),
        Name = Db.Str(r, "name") ?? "",
        Notes = Db.Str(r, "notes"),
        Status = ProjectStatusExtensions.FromDb(Db.Str(r, "status")!),
        CreatedAt = Db.ParseTime(Db.Str(r, "createdAt")) ?? DateTime.UtcNow,
    };

    public static async Task<List<Project>> ProjectsAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
            Task.FromResult(Db.ReadRows(conn, "SELECT * FROM project ORDER BY createdAt ASC")
                .Select(ReadProject).ToList())).ConfigureAwait(false);

    public static async Task<Project?> ProjectAsync(this AppDatabase db, Guid id) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM project WHERE id=@id", Db.P("@id", Db.Uid(id)));
            return Task.FromResult(rows.Count == 0 ? null : ReadProject(rows[0]));
        }).ConfigureAwait(false);

    /// <summary>新项目默认"待整理"（R-008）。</summary>
    public static async Task<Project> CreateProjectAsync(this AppDatabase db, string name)
    {
        var project = new Project { Name = name };
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, "INSERT INTO project (id,name,notes,status,createdAt) VALUES (@id,@name,NULL,'inbox',@createdAt)",
                Db.P("@id", Db.Uid(project.Id)),
                Db.P("@name", project.Name),
                Db.P("@createdAt", Db.Fmt(project.CreatedAt)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);
        return project;
    }

    public static Task RenameProjectAsync(this AppDatabase db, Guid id, string name) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE project SET name=@name WHERE id=@id",
                Db.P("@name", name), Db.P("@id", Db.Uid(id)));
            return Task.CompletedTask;
        });

    /// <summary>状态可任意切换，不改草稿正文或关系（R-008）。</summary>
    public static Task SetProjectStatusAsync(this AppDatabase db, Guid id, ProjectStatus status) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE project SET status=@s WHERE id=@id",
                Db.P("@s", status.DbValue()), Db.P("@id", Db.Uid(id)));
            return Task.CompletedTask;
        });

    /// <summary>删除项目保留草稿（R-005）：projectDraft 级联删除，草稿内容仍在。</summary>
    public static Task DeleteProjectAsync(this AppDatabase db, Guid id) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, "DELETE FROM project WHERE id=@id", Db.P("@id", Db.Uid(id)));
            return Task.CompletedTask;
        });

    // ---- 归属 ----

    /// <summary>加入项目；草稿或项目不存在、或已归属时返回 false（幂等）。</summary>
    public static async Task<bool> AddDraftToProjectAsync(this AppDatabase db, Guid draftId, Guid projectId) =>
        await db.WriteAsync(conn =>
        {
            if (Db.Long(conn, "SELECT count(*) FROM draft WHERE id=@d", Db.P("@d", Db.Uid(draftId))) == 0) return Task.FromResult(false);
            if (Db.Long(conn, "SELECT count(*) FROM project WHERE id=@p", Db.P("@p", Db.Uid(projectId))) == 0) return Task.FromResult(false);
            if (Db.Long(conn, """
                SELECT count(*) FROM projectDraft WHERE projectId=@p AND draftId=@d
                """, Db.P("@p", Db.Uid(projectId)), Db.P("@d", Db.Uid(draftId))) > 0) return Task.FromResult(false);
            Db.Exec(conn, "INSERT INTO projectDraft (projectId,draftId) VALUES (@p,@d)",
                Db.P("@p", Db.Uid(projectId)), Db.P("@d", Db.Uid(draftId)));
            return Task.FromResult(true);
        }).ConfigureAwait(false);

    /// <summary>从项目移除；不影响其他项目（R-005）。</summary>
    public static async Task<bool> RemoveDraftFromProjectAsync(this AppDatabase db, Guid draftId, Guid projectId) =>
        await db.WriteAsync(conn =>
        {
            var n = Db.Exec(conn, "DELETE FROM projectDraft WHERE projectId=@p AND draftId=@d",
                Db.P("@p", Db.Uid(projectId)), Db.P("@d", Db.Uid(draftId)));
            return Task.FromResult(n > 0);
        }).ConfigureAwait(false);

    public static async Task<List<Draft>> DraftsInProjectAsync(this AppDatabase db, Guid projectId) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT draft.* FROM draft
                JOIN projectDraft ON projectDraft.draftId = draft.id
                WHERE projectDraft.projectId = @p
                ORDER BY draft.importedAt DESC
                """, Db.P("@p", Db.Uid(projectId)));
            return Task.FromResult(rows.Select(r => new Draft
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
            }).ToList());
        }).ConfigureAwait(false);

    public static async Task<List<Project>> ProjectsContainingAsync(this AppDatabase db, Guid draftId) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT project.* FROM project
                JOIN projectDraft ON projectDraft.projectId = project.id
                WHERE projectDraft.draftId = @d
                ORDER BY project.createdAt ASC
                """, Db.P("@d", Db.Uid(draftId)));
            return Task.FromResult(rows.Select(ReadProject).ToList());
        }).ConfigureAwait(false);

    /// <summary>草稿卡片上的"所属项目数"。</summary>
    public static async Task<Dictionary<Guid, int>> ProjectCountsByDraftAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT draftId, COUNT(*) AS count FROM projectDraft GROUP BY draftId");
            var result = new Dictionary<Guid, int>();
            foreach (var r in rows)
            {
                if (Db.Str(r, "draftId") is { } idStr)
                {
                    result[Db.Uid(idStr)] = (int)Db.Int(r, "count");
                }
            }
            return Task.FromResult(result);
        }).ConfigureAwait(false);

    // ---- 标签（R-008） ----

    /// <summary>同名标签不会重复创建（R-008 验收）。</summary>
    public static async Task<Tag> UpsertTagAsync(this AppDatabase db, string name) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM tag WHERE name=@n", Db.P("@n", name));
            if (rows.Count > 0)
            {
                return Task.FromResult(new Tag { Id = Db.Uid(Db.Str(rows[0], "id")!), Name = Db.Str(rows[0], "name")! });
            }
            var tag = new Tag { Name = name };
            Db.Exec(conn, "INSERT INTO tag (id,name) VALUES (@id,@n)",
                Db.P("@id", Db.Uid(tag.Id)), Db.P("@n", tag.Name));
            return Task.FromResult(tag);
        }).ConfigureAwait(false);

    public static async Task AddTagToProjectAsync(this AppDatabase db, string name, Guid projectId) =>
        await db.WriteAsync(conn =>
        {
            // 写锁不可重入：此处内联标签 upsert，不得调用 UpsertTagAsync。
            var tagRows = Db.ReadRows(conn, "SELECT * FROM tag WHERE name=@n", Db.P("@n", name));
            Guid tagId;
            if (tagRows.Count > 0)
            {
                tagId = Db.Uid(Db.Str(tagRows[0], "id")!);
            }
            else
            {
                tagId = Guid.NewGuid();
                Db.Exec(conn, "INSERT INTO tag (id,name) VALUES (@id,@n)",
                    Db.P("@id", Db.Uid(tagId)), Db.P("@n", name));
            }
            if (Db.Long(conn, "SELECT count(*) FROM project WHERE id=@p", Db.P("@p", Db.Uid(projectId))) == 0)
            {
                return Task.CompletedTask;
            }
            if (Db.Long(conn, "SELECT count(*) FROM projectTag WHERE projectId=@p AND tagId=@t",
                Db.P("@p", Db.Uid(projectId)), Db.P("@t", Db.Uid(tagId))) > 0)
            {
                return Task.CompletedTask;
            }
            Db.Exec(conn, "INSERT INTO projectTag (projectId,tagId) VALUES (@p,@t)",
                Db.P("@p", Db.Uid(projectId)), Db.P("@t", Db.Uid(tagId)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    public static Task RemoveTagFromProjectAsync(this AppDatabase db, string name, Guid projectId) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, """
                DELETE FROM projectTag WHERE projectId=@p AND tagId IN (SELECT id FROM tag WHERE name=@n)
                """, Db.P("@p", Db.Uid(projectId)), Db.P("@n", name));
            return Task.CompletedTask;
        });

    public static async Task<List<Tag>> TagsAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
            Task.FromResult(Db.ReadRows(conn, "SELECT * FROM tag ORDER BY name ASC").Select(r => new Tag
            {
                Id = Db.Uid(Db.Str(r, "id")!),
                Name = Db.Str(r, "name") ?? "",
            }).ToList())).ConfigureAwait(false);

    /// <summary>全部项目-草稿成员关系（导出用）。</summary>
    public static async Task<List<(Guid ProjectId, Guid DraftId)>> MembershipsAsync(this AppDatabase db) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT projectId, draftId FROM projectDraft ORDER BY projectId, draftId");
            var list = new List<(Guid, Guid)>(rows.Count);
            foreach (var r in rows)
            {
                if (Db.Str(r, "projectId") is { } p && Db.Str(r, "draftId") is { } d)
                {
                    list.Add((Db.Uid(p), Db.Uid(d)));
                }
            }
            return Task.FromResult(list);
        }).ConfigureAwait(false);

    public static async Task<List<Tag>> TagsOnProjectAsync(this AppDatabase db, Guid projectId) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT tag.* FROM tag
                JOIN projectTag ON projectTag.tagId = tag.id
                WHERE projectTag.projectId = @p
                ORDER BY tag.name ASC
                """, Db.P("@p", Db.Uid(projectId)));
            return Task.FromResult(rows.Select(r => new Tag
            {
                Id = Db.Uid(Db.Str(r, "id")!),
                Name = Db.Str(r, "name") ?? "",
            }).ToList());
        }).ConfigureAwait(false);

    public static async Task<List<Project>> ProjectsWithTagAsync(this AppDatabase db, string name) =>
        await db.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, """
                SELECT project.* FROM project
                JOIN projectTag ON projectTag.projectId = project.id
                JOIN tag ON tag.id = projectTag.tagId
                WHERE tag.name = @n
                ORDER BY project.createdAt ASC
                """, Db.P("@n", name));
            return Task.FromResult(rows.Select(ReadProject).ToList());
        }).ConfigureAwait(false);
}
