using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DraftZero.Core;

/// <summary>
/// .dzarchive 迁移档案（计划 §3 数据契约，formatVersion=1）。
/// ZIP 容器：manifest.json + data/*.json + pdf/*.pdf；JSON 统一 UTF-8、UUID 规范字符串、
/// ISO-8601 UTC 时间、相对路径。不导出向量/索引/候选分数/机器绝对快照路径/密钥（Mac 导出端同契约）。
/// </summary>
public static class DzArchiveFormat
{
    public const int FormatVersion = 1;
    public const string ManifestEntry = "manifest.json";

    /// <summary>导入防御上限（计划 §3：ZIP 解压总量上限与条目上限）。</summary>
    public const int MaxEntries = 20_000;
    public const long MaxTotalUncompressedBytes = 4L * 1024 * 1024 * 1024; // 4 GiB
    public const long MaxSingleEntryBytes = 2L * 1024 * 1024 * 1024;       // 2 GiB
}

public sealed class DzManifest
{
    [JsonPropertyName("formatVersion")] public int FormatVersion { get; set; }
    [JsonPropertyName("application")] public string Application { get; set; } = "DraftZero";
    [JsonPropertyName("exportedByVersion")] public string ExportedByVersion { get; set; } = "";
    [JsonPropertyName("exportedAt")] public string ExportedAt { get; set; } = "";
    [JsonPropertyName("files")] public List<DzManifestFile> Files { get; set; } = [];
    [JsonPropertyName("counts")] public DzCounts? Counts { get; set; }
}

public sealed class DzManifestFile
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("sizeBytes")] public long SizeBytes { get; set; }
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
}

public sealed class DzCounts
{
    [JsonPropertyName("drafts")] public int Drafts { get; set; }
    [JsonPropertyName("versions")] public int Versions { get; set; }
    [JsonPropertyName("projects")] public int Projects { get; set; }
    [JsonPropertyName("memberships")] public int Memberships { get; set; }
    [JsonPropertyName("relations")] public int Relations { get; set; }
    [JsonPropertyName("tags")] public int Tags { get; set; }
    [JsonPropertyName("projectTags")] public int ProjectTags { get; set; }
    [JsonPropertyName("candidateDecisions")] public int CandidateDecisions { get; set; }
    [JsonPropertyName("remoteSuggestions")] public int RemoteSuggestions { get; set; }
    [JsonPropertyName("pdfSnapshots")] public int PdfSnapshots { get; set; }
}

public sealed class DzDraft
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("content")] public string? Content { get; set; }
    [JsonPropertyName("isEditable")] public bool IsEditable { get; set; }
    [JsonPropertyName("hasExtractableText")] public bool HasExtractableText { get; set; } = true;
    [JsonPropertyName("sourceType")] public string SourceType { get; set; } = "";
    [JsonPropertyName("sourceLocation")] public string? SourceLocation { get; set; }
    [JsonPropertyName("sourceLabel")] public string? SourceLabel { get; set; }
    [JsonPropertyName("fingerprint")] public string? Fingerprint { get; set; }
    [JsonPropertyName("sourceVersionSha")] public string? SourceVersionSha { get; set; }
    [JsonPropertyName("importedAt")] public string ImportedAt { get; set; } = "";
    /// <summary>档案内 PDF 快照的相对路径（如 "pdf/abc.pdf"）；非 PDF 为 null。</summary>
    [JsonPropertyName("snapshotFile")] public string? SnapshotFile { get; set; }
}

public sealed class DzVersion
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("draftId")] public string DraftId { get; set; } = "";
    [JsonPropertyName("content")] public string Content { get; set; } = "";
    [JsonPropertyName("origin")] public string Origin { get; set; } = "";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
}

public sealed class DzRelation
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("sourceDraftId")] public string SourceDraftId { get; set; } = "";
    [JsonPropertyName("targetDraftId")] public string TargetDraftId { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("note")] public string? Note { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
}

public sealed class DzProject
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("notes")] public string? Notes { get; set; }
    [JsonPropertyName("status")] public string Status { get; set; } = "inbox";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
}

public sealed class DzMembership
{
    [JsonPropertyName("projectId")] public string ProjectId { get; set; } = "";
    [JsonPropertyName("draftId")] public string DraftId { get; set; } = "";
}

public sealed class DzTags
{
    [JsonPropertyName("tags")] public List<DzTag> Tags { get; set; } = [];
    [JsonPropertyName("memberships")] public List<DzProjectTag> Memberships { get; set; } = [];
}

public sealed class DzTag
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
}

public sealed class DzProjectTag
{
    [JsonPropertyName("projectId")] public string ProjectId { get; set; } = "";
    [JsonPropertyName("tagId")] public string TagId { get; set; } = "";
}

/// <summary>候选裁决行：不含分数与证据（可重建数据不迁移，计划 §3）。</summary>
public sealed class DzCandidateDecision
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("draftA")] public string DraftA { get; set; } = "";
    [JsonPropertyName("draftB")] public string DraftB { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("fingerprintA")] public string? FingerprintA { get; set; }
    [JsonPropertyName("fingerprintB")] public string? FingerprintB { get; set; }
    [JsonPropertyName("lastDecision")] public string? LastDecision { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("decidedAt")] public string? DecidedAt { get; set; }
}

public sealed class DzRemoteSuggestion
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("draftIds")] public List<string> DraftIds { get; set; } = [];
    [JsonPropertyName("explanation")] public string? Explanation { get; set; }
    [JsonPropertyName("citations")] public List<DzCitation>? Citations { get; set; }
    [JsonPropertyName("notice")] public string? Notice { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("dismissed")] public bool Dismissed { get; set; }
}

public sealed class DzCitation
{
    [JsonPropertyName("draftId")] public string DraftId { get; set; } = "";
    [JsonPropertyName("quote")] public string Quote { get; set; } = "";
}

public sealed record DzArchiveContents(
    DzManifest Manifest,
    List<DzDraft> Drafts,
    List<DzVersion> Versions,
    List<DzRelation> Relations,
    List<DzProject> Projects,
    List<DzTag> Tags,
    List<DzProjectTag> ProjectTags,
    List<DzMembership> Memberships,
    List<DzCandidateDecision> CandidateDecisions,
    List<DzRemoteSuggestion> RemoteSuggestions,
    Dictionary<string, byte[]> PdfEntries);

public class DzArchiveException : Exception
{
    public DzArchiveException(string message) : base(message) { }
}

/// <summary>.dzarchive 读取与校验（计划 §3：先验证完整性与引用，再写入）。</summary>
public static class DzArchiveReader
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Disallow,
    };

    /// <summary>读取并全面校验档案；任何一步失败抛 DzArchiveException，不做任何写入。</summary>
    public static async Task<DzArchiveContents> ReadAsync(string archivePath, CancellationToken ct = default)
    {
        if (!File.Exists(archivePath))
        {
            throw new DzArchiveException("找不到迁移档案文件");
        }

        using var zip = ZipFile.OpenRead(archivePath);
        var entries = zip.Entries;
        if (entries.Count > DzArchiveFormat.MaxEntries)
        {
            throw new DzArchiveException($"档案条目数超过上限（{entries.Count} > {DzArchiveFormat.MaxEntries}）");
        }

        // 路径合法性：相对路径，禁止绝对路径、..、盘符、重复条目。
        var seenPaths = new HashSet<string>(StringComparer.Ordinal);
        long totalBytes = 0;
        foreach (var entry in entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            if (Path.IsPathRooted(name) || name.Contains(':') || name.StartsWith('/'))
            {
                throw new DzArchiveException($"档案包含非法绝对路径：{name}");
            }
            var segments = name.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (segments.Length == 0) continue; // 目录条目
            if (segments.Any(s => s == ".."))
            {
                throw new DzArchiveException($"档案包含越级路径（..）：{name}");
            }
            if (!seenPaths.Add(name))
            {
                throw new DzArchiveException($"档案包含重复路径：{name}");
            }
            if (entry.Length > DzArchiveFormat.MaxSingleEntryBytes)
            {
                throw new DzArchiveException($"档案条目过大：{name}");
            }
            totalBytes += entry.Length;
            if (totalBytes > DzArchiveFormat.MaxTotalUncompressedBytes)
            {
                throw new DzArchiveException("档案解压总量超过上限");
            }
        }

        // manifest.json
        var manifestEntry = entries.FirstOrDefault(e => e.FullName == DzArchiveFormat.ManifestEntry)
            ?? throw new DzArchiveException("档案缺少 manifest.json");
        DzManifest manifest;
        try
        {
            await using var stream = manifestEntry.Open();
            manifest = await JsonSerializer.DeserializeAsync<DzManifest>(stream, JsonOpts, ct).ConfigureAwait(false)
                ?? throw new DzArchiveException("manifest.json 无法解析");
        }
        catch (JsonException ex)
        {
            throw new DzArchiveException($"manifest.json 无法解析：{ex.Message}");
        }
        if (manifest.FormatVersion != DzArchiveFormat.FormatVersion)
        {
            throw new DzArchiveException($"档案格式版本不受支持：{manifest.FormatVersion}（本应用支持 {DzArchiveFormat.FormatVersion}）");
        }

        // 逐文件 SHA-256 校验。
        var entryByName = entries.ToDictionary(e => e.FullName.Replace('\\', '/'), StringComparer.Ordinal);
        foreach (var file in manifest.Files)
        {
            if (!entryByName.TryGetValue(file.Path, out var entry))
            {
                throw new DzArchiveException($"manifest 引用的文件缺失：{file.Path}");
            }
            await using var stream = entry.Open();
            using var hashBuffer = new MemoryStream();
            await stream.CopyToAsync(hashBuffer, ct).ConfigureAwait(false);
            var hash = Convert.ToHexString(SHA256.HashData(hashBuffer.ToArray()));
            if (!hash.Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new DzArchiveException($"文件校验失败（SHA-256 不符）：{file.Path}");
            }
            if (entry.Length != file.SizeBytes)
            {
                throw new DzArchiveException($"文件大小与 manifest 不符：{file.Path}");
            }
        }

        // 数据文件反序列化。
        var drafts = await ReadJsonAsync<List<DzDraft>>(entryByName, "data/drafts.json", ct).ConfigureAwait(false);
        var versions = await ReadJsonAsync<List<DzVersion>>(entryByName, "data/versions.json", ct).ConfigureAwait(false);
        var relations = await ReadJsonAsync<List<DzRelation>>(entryByName, "data/relations.json", ct).ConfigureAwait(false);
        var projects = await ReadJsonAsync<List<DzProject>>(entryByName, "data/projects.json", ct).ConfigureAwait(false);
        var tags = await ReadJsonAsync<DzTags>(entryByName, "data/tags.json", ct).ConfigureAwait(false);
        var memberships = await ReadJsonAsync<List<DzMembership>>(entryByName, "data/memberships.json", ct).ConfigureAwait(false);
        var candidates = await ReadJsonAsync<List<DzCandidateDecision>>(entryByName, "data/candidates.json", ct).ConfigureAwait(false);
        var suggestions = await ReadJsonAsync<List<DzRemoteSuggestion>>(entryByName, "data/remoteSuggestions.json", ct).ConfigureAwait(false);

        // PDF 快照条目。
        var pdfEntries = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var draft in drafts)
        {
            if (draft.SnapshotFile is null) continue;
            if (!entryByName.TryGetValue(draft.SnapshotFile, out var entry))
            {
                throw new DzArchiveException($"草稿引用的 PDF 快照缺失：{draft.SnapshotFile}");
            }
            await using var stream = entry.Open();
            using var buffer = new MemoryStream();
            await stream.CopyToAsync(buffer, ct).ConfigureAwait(false);
            pdfEntries[draft.SnapshotFile] = buffer.ToArray();
        }

        var contents = new DzArchiveContents(
            manifest, drafts ?? [], versions ?? [], relations ?? [], projects ?? [],
            tags?.Tags ?? [], tags?.Memberships ?? [], memberships ?? [], candidates ?? [], suggestions ?? [], pdfEntries);
        ValidateReferences(contents);
        return contents;
    }

    /// <summary>引用完整性：所有外键必须指向档案内存在的记录；ID 必须是规范 UUID。</summary>
    private static void ValidateReferences(DzArchiveContents c)
    {
        var draftIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var d in c.Drafts)
        {
            if (!IsValidUuid(d.Id)) throw new DzArchiveException("草稿 ID 不是规范 UUID");
            if (string.IsNullOrWhiteSpace(d.Title)) throw new DzArchiveException("存在标题为空的草稿");
            if (!draftIds.Add(d.Id)) throw new DzArchiveException($"档案中存在重复草稿 ID：{d.Id}");
            try { SourceTypeExtensions.FromDb(d.SourceType); }
            catch (FormatException) { throw new DzArchiveException($"草稿 {d.Id} 的来源类型不可识别：{d.SourceType}"); }
        }
        var projectIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var p in c.Projects)
        {
            if (!IsValidUuid(p.Id)) throw new DzArchiveException("项目 ID 不是规范 UUID");
            if (string.IsNullOrWhiteSpace(p.Name)) throw new DzArchiveException("存在名称为空的项目");
            if (!projectIds.Add(p.Id)) throw new DzArchiveException($"档案中存在重复项目 ID：{p.Id}");
        }
        var tagIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in c.Tags)
        {
            if (!IsValidUuid(t.Id)) throw new DzArchiveException("标签 ID 不是规范 UUID");
            if (!tagIds.Add(t.Id)) throw new DzArchiveException($"档案中存在重复标签 ID：{t.Id}");
        }
        var versionIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var v in c.Versions)
        {
            if (!IsValidUuid(v.Id)) throw new DzArchiveException("版本 ID 不是规范 UUID");
            if (!versionIds.Add(v.Id)) throw new DzArchiveException($"档案中存在重复版本 ID：{v.Id}");
            if (!draftIds.Contains(v.DraftId)) throw new DzArchiveException($"版本 {v.Id} 引用了不存在的草稿");
        }
        foreach (var r in c.Relations)
        {
            if (!IsValidUuid(r.Id)) throw new DzArchiveException("关系 ID 不是规范 UUID");
            if (!draftIds.Contains(r.SourceDraftId) || !draftIds.Contains(r.TargetDraftId))
            {
                throw new DzArchiveException($"关系 {r.Id} 引用了不存在的草稿");
            }
        }
        foreach (var m in c.ProjectTags)
        {
            if (!projectIds.Contains(m.ProjectId) || !tagIds.Contains(m.TagId))
            {
                throw new DzArchiveException("项目-标签关系引用了不存在的记录");
            }
        }
        foreach (var m in c.Memberships)
        {
            if (!projectIds.Contains(m.ProjectId) || !draftIds.Contains(m.DraftId))
            {
                throw new DzArchiveException("项目成员关系引用了不存在的记录");
            }
        }
        foreach (var cd in c.CandidateDecisions)
        {
            if (!IsValidUuid(cd.Id)) throw new DzArchiveException("候选裁决 ID 不是规范 UUID");
            if (!draftIds.Contains(cd.DraftA) || !draftIds.Contains(cd.DraftB))
            {
                throw new DzArchiveException($"候选裁决 {cd.Id} 引用了不存在的草稿");
            }
        }
        foreach (var s in c.RemoteSuggestions)
        {
            if (!IsValidUuid(s.Id)) throw new DzArchiveException("远程建议 ID 不是规范 UUID");
            foreach (var draftId in s.DraftIds)
            {
                if (!draftIds.Contains(draftId))
                {
                    throw new DzArchiveException($"远程建议 {s.Id} 引用了不存在的草稿");
                }
            }
            foreach (var citation in s.Citations ?? [])
            {
                if (!draftIds.Contains(citation.DraftId))
                {
                    throw new DzArchiveException($"远程建议 {s.Id} 的引用指向不存在的草稿");
                }
            }
        }
        if (c.Manifest.Counts is { } counts && counts.Drafts != c.Drafts.Count)
        {
            throw new DzArchiveException("manifest 记录数与实际数据不一致（drafts）");
        }
        if (c.Manifest.Counts is { } counts2 && counts2.Memberships != c.Memberships.Count)
        {
            throw new DzArchiveException("manifest 记录数与实际数据不一致（memberships）");
        }
    }

    private static bool IsValidUuid(string s) => Guid.TryParseExact(s, "D", out _);

    private static async Task<T?> ReadJsonAsync<T>(Dictionary<string, ZipArchiveEntry> entries, string path, CancellationToken ct)
    {
        if (!entries.TryGetValue(path, out var entry))
        {
            throw new DzArchiveException($"档案缺少数据文件：{path}");
        }
        await using var stream = entry.Open();
        try
        {
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOpts, ct).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            throw new DzArchiveException($"{path} 无法解析：{ex.Message}");
        }
    }
}

/// <summary>
/// Windows 空工作区一次性导入（计划 §3 / W-011）：
/// 仅允许空库；先写项目内临时库，全部成功后原子替换，失败零部分写入；
/// PDF 快照重绑到 Windows 工作区自己的 snapshots 目录；
/// 裁决行原样入库以保留抑制规则；导入后由调用方重建索引与候选。
/// </summary>
public static class WorkspaceImporter
{
    public static bool IsWorkspaceEmpty(AppDatabase db)
    {
        var n = db.WriteAsync(conn => Task.FromResult(
            Db.Long(conn, "SELECT (SELECT count(*) FROM draft) + (SELECT count(*) FROM project) + (SELECT count(*) FROM candidatePair) + (SELECT count(*) FROM remoteSuggestion)")))
            .ConfigureAwait(false).GetAwaiter().GetResult();
        return n == 0;
    }

    public static async Task<DzCounts> ImportAsync(AppDatabase db, string archivePath, CancellationToken ct = default)
    {
        var contents = await DzArchiveReader.ReadAsync(archivePath, ct).ConfigureAwait(false);

        if (!IsWorkspaceEmpty(db))
        {
            throw new DzArchiveException(
                "当前 Windows 工作区已有内容。迁移仅支持导入到空工作区；请先备份或另建空工作区（不做自动合并）。");
        }

        var importId = Guid.NewGuid().ToString("N");
        var tempDbPath = Path.Combine(db.WorkspaceDirectory, $".import-{importId}.sqlite");
        var tempSnapshotDir = Path.Combine(db.WorkspaceDirectory, $".import-{importId}-snapshots");
        Directory.CreateDirectory(tempSnapshotDir);

        try
        {
            await using var tempDb = new AppDatabase(tempDbPath);
            var counts = await WriteAllAsync(tempDb, contents, tempSnapshotDir, db.SnapshotsDirectory, ct).ConfigureAwait(false);
            await tempDb.DisposeAsync().ConfigureAwait(false);

            // 全部成功：原子替换空库（WAL 一并处理）+ 落位 PDF 快照。
            await db.DisposeAsync().ConfigureAwait(false);
            foreach (var suffix in new[] { "", "-wal", "-shm" })
            {
                var old = db.DatabasePath + suffix;
                if (File.Exists(old)) File.Delete(old);
            }
            File.Move(tempDbPath, db.DatabasePath);
            foreach (var suffix in new[] { "-wal", "-shm" })
            {
                if (File.Exists(tempDbPath + suffix))
                {
                    File.Move(tempDbPath + suffix, db.DatabasePath + suffix);
                }
            }
            Directory.CreateDirectory(db.SnapshotsDirectory);
            foreach (var file in Directory.GetFiles(tempSnapshotDir))
            {
                File.Move(file, Path.Combine(db.SnapshotsDirectory, Path.GetFileName(file)), overwrite: true);
            }
            Directory.Delete(tempSnapshotDir, recursive: true);
            return counts;
        }
        catch
        {
            // 失败零部分写入：清理临时库与临时快照，主库未被触碰。
            try
            {
                foreach (var suffix in new[] { "", "-wal", "-shm" })
                {
                    if (File.Exists(tempDbPath + suffix)) File.Delete(tempDbPath + suffix);
                }
                if (Directory.Exists(tempSnapshotDir)) Directory.Delete(tempSnapshotDir, recursive: true);
            }
            catch
            {
                // 清理失败不掩盖原始错误。
            }
            throw;
        }
    }

    private static async Task<DzCounts> WriteAllAsync(AppDatabase tempDb, DzArchiveContents c,
        string tempSnapshotDir, string finalSnapshotsDir, CancellationToken ct)
    {
        // PDF 快照先写临时目录，导入成功后由调用方落位到 finalSnapshotsDir；
        // 草稿行内预先保存**最终** snapshots 路径（路径重绑，计划 §3）。
        foreach (var (entryPath, data) in c.PdfEntries)
        {
            var fileName = Path.GetFileName(entryPath.Replace('\\', '/'));
            await File.WriteAllBytesAsync(Path.Combine(tempSnapshotDir, $"dz-{fileName}"), data, ct).ConfigureAwait(false);
        }
        var snapshotFileByEntry = c.PdfEntries.Keys.ToDictionary(
            k => k,
            k => Path.Combine(finalSnapshotsDir, $"dz-{Path.GetFileName(k.Replace('\\', '/'))}"),
            StringComparer.Ordinal);

        await tempDb.WriteAsync(async conn =>
        {
            using var tx = conn.BeginTransaction();
            foreach (var draft in c.Drafts)
            {
                var snapshotPath = draft.SnapshotFile is not null
                    ? snapshotFileByEntry[draft.SnapshotFile]
                    : null;
                Db.Exec(conn, """
                    INSERT INTO draft (id,title,content,isEditable,hasExtractableText,sourceType,sourceLocation,sourceLabel,snapshotFileURL,fingerprint,sourceVersionSha,importedAt)
                    VALUES (@id,@title,@content,@isEditable,@hasText,@sourceType,@sourceLocation,@sourceLabel,@snapshot,@fp,@vsha,@importedAt)
                    """,
                    Db.P("@id", draft.Id.ToUpperInvariant()),
                    Db.P("@title", draft.Title),
                    Db.P("@content", draft.Content),
                    Db.P("@isEditable", draft.IsEditable ? 1L : 0L),
                    Db.P("@hasText", draft.HasExtractableText ? 1L : 0L),
                    Db.P("@sourceType", draft.SourceType),
                    Db.P("@sourceLocation", draft.SourceLocation),
                    Db.P("@sourceLabel", draft.SourceLabel),
                    Db.P("@snapshot", snapshotPath),
                    Db.P("@fp", draft.Fingerprint),
                    Db.P("@vsha", draft.SourceVersionSha),
                    Db.P("@importedAt", draft.ImportedAt));
            }
            foreach (var v in c.Versions)
            {
                Db.Exec(conn, """
                    INSERT INTO draftVersion (id,draftId,content,origin,createdAt)
                    VALUES (@id,@draftId,@content,@origin,@createdAt)
                    """,
                    Db.P("@id", v.Id.ToUpperInvariant()),
                    Db.P("@draftId", v.DraftId.ToUpperInvariant()),
                    Db.P("@content", v.Content),
                    Db.P("@origin", v.Origin),
                    Db.P("@createdAt", v.CreatedAt));
            }
            foreach (var r in c.Relations)
            {
                Db.Exec(conn, """
                    INSERT INTO evolutionRelation (id,sourceDraftId,targetDraftId,type,note,createdAt)
                    VALUES (@id,@src,@dst,@type,@note,@createdAt)
                    """,
                    Db.P("@id", r.Id.ToUpperInvariant()),
                    Db.P("@src", r.SourceDraftId.ToUpperInvariant()),
                    Db.P("@dst", r.TargetDraftId.ToUpperInvariant()),
                    Db.P("@type", r.Type),
                    Db.P("@note", r.Note),
                    Db.P("@createdAt", r.CreatedAt));
            }
            foreach (var p in c.Projects)
            {
                Db.Exec(conn, "INSERT INTO project (id,name,notes,status,createdAt) VALUES (@id,@name,@notes,@status,@createdAt)",
                    Db.P("@id", p.Id.ToUpperInvariant()),
                    Db.P("@name", p.Name),
                    Db.P("@notes", p.Notes),
                    Db.P("@status", p.Status),
                    Db.P("@createdAt", p.CreatedAt));
            }
            foreach (var t in c.Tags)
            {
                Db.Exec(conn, "INSERT INTO tag (id,name) VALUES (@id,@name)",
                    Db.P("@id", t.Id.ToUpperInvariant()), Db.P("@name", t.Name));
            }
            foreach (var m in c.ProjectTags)
            {
                Db.Exec(conn, "INSERT INTO projectTag (projectId,tagId) VALUES (@p,@t)",
                    Db.P("@p", m.ProjectId.ToUpperInvariant()), Db.P("@t", m.TagId.ToUpperInvariant()));
            }
            foreach (var m in c.Memberships)
            {
                Db.Exec(conn, "INSERT INTO projectDraft (projectId,draftId) VALUES (@p,@d)",
                    Db.P("@p", m.ProjectId.ToUpperInvariant()), Db.P("@d", m.DraftId.ToUpperInvariant()));
            }
            ct.ThrowIfCancellationRequested();
            foreach (var cd in c.CandidateDecisions)
            {
                // 分数与证据不迁移（可重建数据）；裁决行保留指纹与 lastDecision
                // ——重建候选后，rejected/deferred 且指纹未变的关系不会重新弹出。
                Db.Exec(conn, """
                    INSERT INTO candidatePair (id,draftA,draftB,kind,score,evidence,status,fingerprintA,fingerprintB,lastDecision,createdAt,decidedAt)
                    VALUES (@id,@a,@b,@kind,0,NULL,@status,@fpA,@fpB,@lastDecision,@createdAt,@decidedAt)
                    """,
                    Db.P("@id", cd.Id.ToUpperInvariant()),
                    Db.P("@a", cd.DraftA.ToUpperInvariant()),
                    Db.P("@b", cd.DraftB.ToUpperInvariant()),
                    Db.P("@kind", cd.Kind),
                    Db.P("@status", cd.Status),
                    Db.P("@fpA", cd.FingerprintA),
                    Db.P("@fpB", cd.FingerprintB),
                    Db.P("@lastDecision", cd.LastDecision),
                    Db.P("@createdAt", cd.CreatedAt),
                    Db.P("@decidedAt", cd.DecidedAt));
            }
            foreach (var s in c.RemoteSuggestions)
            {
                var draftIds = JsonSerializer.Serialize(s.DraftIds.Select(Guid.Parse).ToList());
                var citations = s.Citations is null ? null : JsonSerializer.Serialize(
                    s.Citations.Select(x => new RemoteCitation(Guid.Parse(x.DraftId), x.Quote)).ToList());
                Db.Exec(conn, """
                    INSERT INTO remoteSuggestion (id,provider,model,draftIdsData,explanation,citationsData,notice,createdAt,dismissed)
                    VALUES (@id,@provider,@model,@draftIds,@explanation,@citations,@notice,@createdAt,@dismissed)
                    """,
                    Db.P("@id", s.Id.ToUpperInvariant()),
                    Db.P("@provider", s.Provider),
                    Db.P("@model", s.Model),
                    Db.P("@draftIds", draftIds),
                    Db.P("@explanation", s.Explanation),
                    Db.P("@citations", citations),
                    Db.P("@notice", s.Notice),
                    Db.P("@createdAt", s.CreatedAt),
                    Db.P("@dismissed", s.Dismissed ? 1L : 0L));
            }
            tx.Commit();
            return Task.CompletedTask;
        }).ConfigureAwait(false);

        return c.Manifest.Counts ?? new DzCounts();
    }
}
