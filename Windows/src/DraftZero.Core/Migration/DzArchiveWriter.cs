using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace DraftZero.Core;

/// <summary>
/// .dzarchive 导出（D-002 双向迁移）：Windows 工作区 → 档案，供 Mac 端导入。
/// 契约与 Mac 导出器一致（formatVersion=1）：manifest（逐文件 SHA-256 + 计数）+
/// data/*.json + pdf/*；不导出向量/索引、候选分数证据、机器绝对路径、Key。
/// pending 候选不迁移（纯机器建议，可重建）；已接受/拒绝/暂缓裁决随档迁移。
/// </summary>
public static class WorkspaceExporter
{
    private static readonly JsonSerializerOptions WriterJsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public sealed record ExportResult(string Destination, long SizeBytes);

    /// <summary>
    /// 导出当前工作区。重 IO（逐草稿读版本/关系 + PDF 全量读入），调用方应放
    /// Task.Run；progress 每阶段回调一次（可空）。目标已存在时覆盖。
    /// </summary>
    public static async Task<ExportResult> ExportAsync(AppDatabase db, string destination,
        Action<string>? progress = null, CancellationToken ct = default)
    {
        progress?.Invoke("正在读取草稿与关联数据…");
        var drafts = await db.DraftsAsync().ConfigureAwait(false);
        var projects = await db.ProjectsAsync().ConfigureAwait(false);
        var tags = await db.TagsAsync().ConfigureAwait(false);

        var versions = new List<DzVersion>();
        var relations = new List<DzRelation>();
        var decisions = new List<DzCandidateDecision>();
        foreach (var draft in drafts)
        {
            foreach (var v in await db.VersionsAsync(draft.Id).ConfigureAwait(false))
            {
                versions.Add(new DzVersion
                {
                    Id = Db.Uid(v.Id), DraftId = Db.Uid(v.DraftId), Content = v.Content,
                    Origin = v.Origin.DbValue(), CreatedAt = Db.Fmt(v.CreatedAt),
                });
            }
            foreach (var r in await db.RelationsAsync(draft.Id).ConfigureAwait(false))
            {
                // 关系按 source 去重（ RelationsAsync 双端都能查到同一条）
                if (!relations.Any(x => x.Id == Db.Uid(r.Id)))
                {
                    relations.Add(new DzRelation
                    {
                        Id = Db.Uid(r.Id),
                        SourceDraftId = Db.Uid(r.SourceDraftId),
                        TargetDraftId = Db.Uid(r.TargetDraftId),
                        Type = r.Type.DbValue(), Note = r.Note,
                        CreatedAt = Db.Fmt(r.CreatedAt),
                    });
                }
            }
        }
        var projectTags = new List<DzProjectTag>();
        var memberships = new List<DzMembership>();
        foreach (var project in projects)
        {
            foreach (var t in await db.TagsOnProjectAsync(project.Id).ConfigureAwait(false))
            {
                projectTags.Add(new DzProjectTag { ProjectId = Db.Uid(project.Id), TagId = Db.Uid(t.Id) });
            }
            foreach (var m in await db.MembershipsAsync().ConfigureAwait(false))
            {
                memberships.Add(new DzMembership { ProjectId = Db.Uid(m.ProjectId), DraftId = Db.Uid(m.DraftId) });
            }
        }

        // 用户裁决（accepted/rejected/deferred；pending 是纯机器建议不迁移）
        await db.WriteAsync(conn =>
        {
            foreach (var r in Db.ReadRows(conn, "SELECT * FROM candidatePair WHERE status != 'pending' ORDER BY createdAt"))
            {
                decisions.Add(new DzCandidateDecision
                {
                    Id = Db.Str(r, "id") ?? "",
                    DraftA = Db.Str(r, "draftA") ?? "",
                    DraftB = Db.Str(r, "draftB") ?? "",
                    Kind = Db.Str(r, "kind") ?? "",
                    Status = Db.Str(r, "status") ?? "",
                    FingerprintA = Db.Str(r, "fingerprintA"),
                    FingerprintB = Db.Str(r, "fingerprintB"),
                    LastDecision = Db.Str(r, "lastDecision"),
                    CreatedAt = Db.Str(r, "createdAt") ?? "",
                    DecidedAt = Db.Str(r, "decidedAt"),
                });
            }
            return Task.CompletedTask;
        }).ConfigureAwait(false);

        var suggestions = await db.PendingRemoteSuggestionsAsync().ConfigureAwait(false);
        var archiveSuggestions = suggestions.Select(sv => new DzRemoteSuggestion
        {
            Id = Db.Uid(sv.Id), Provider = sv.Provider, Model = sv.Model,
            DraftIds = sv.DraftIds.Select(Db.Uid).ToList(),
            Explanation = sv.Explanation,
            Citations = sv.Citations.Select(c => new DzCitation { DraftId = Db.Uid(c.DraftId), Quote = c.Quote }).ToList(),
            Notice = sv.Notice, CreatedAt = Db.Fmt(sv.CreatedAt), Dismissed = sv.Dismissed,
        }).ToList();

        progress?.Invoke("正在打包 PDF 快照…");
        var pdfEntries = new List<(string Entry, string SourcePath)>();
        foreach (var draft in drafts)
        {
            if (string.IsNullOrEmpty(draft.SnapshotFileURL)) continue;
            if (!File.Exists(draft.SnapshotFileURL))
            {
                throw new FileNotFoundException($"PDF 快照文件缺失：{draft.SnapshotFileURL}");
            }
            pdfEntries.Add(("pdf/" + Path.GetFileName(draft.SnapshotFileURL), draft.SnapshotFileURL));
        }

        var archiveDrafts = drafts.Select(d => new DzDraft
        {
            Id = Db.Uid(d.Id), Title = d.Title, Content = d.Content,
            IsEditable = d.IsEditable, HasExtractableText = d.HasExtractableText,
            SourceType = d.SourceType.DbValue(), SourceLocation = d.SourceLocation,
            SourceLabel = d.SourceLabel, Fingerprint = d.Fingerprint,
            SourceVersionSha = d.SourceVersionSha, ImportedAt = Db.Fmt(d.ImportedAt),
            SnapshotFile = string.IsNullOrEmpty(d.SnapshotFileURL)
                ? null : "pdf/" + Path.GetFileName(d.SnapshotFileURL),
        }).ToList();
        var archiveProjects = projects.Select(p => new DzProject
        {
            Id = Db.Uid(p.Id), Name = p.Name, Notes = p.Notes,
            Status = p.Status.DbValue(), CreatedAt = Db.Fmt(p.CreatedAt),
        }).ToList();
        var archiveTags = new DzTags
        {
            Tags = tags.Select(t => new DzTag { Id = Db.Uid(t.Id), Name = t.Name }).ToList(),
            Memberships = projectTags,
        };

        var counts = new DzCounts
        {
            Drafts = archiveDrafts.Count, Versions = versions.Count,
            Projects = archiveProjects.Count, Memberships = memberships.Count,
            Relations = relations.Count, Tags = archiveTags.Tags.Count,
            ProjectTags = archiveTags.Memberships.Count,
            CandidateDecisions = decisions.Count,
            RemoteSuggestions = archiveSuggestions.Count,
            PdfSnapshots = pdfEntries.Count,
        };

        ct.ThrowIfCancellationRequested();
        progress?.Invoke("正在写入档案（含 PDF，约数十秒）…");

        // 原子写：临时文件 → 改名。
        var tempPath = destination + ".tmp";
        // Create 模式的 ZipArchive 不支持回头读条目 → 写入时同步算哈希
        var files = new List<DzManifestFile>();
        await using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
        await using (var zip = new ZipArchive(fs, ZipArchiveMode.Create))
        {
            void AddBytes(string entry, byte[] bytes)
            {
                var e = zip.CreateEntry(entry, CompressionLevel.Optimal);
                using var stream = e.Open();
                stream.Write(bytes);
                files.Add(new DzManifestFile
                {
                    Path = entry, SizeBytes = bytes.Length,
                    Sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
                });
            }
            void AddJson<T>(string entry, T value) =>
                AddBytes(entry, JsonSerializer.SerializeToUtf8Bytes(value, WriterJsonOpts));

            AddJson("data/drafts.json", archiveDrafts);
            AddJson("data/versions.json", versions);
            AddJson("data/relations.json", relations);
            AddJson("data/projects.json", archiveProjects);
            AddJson("data/tags.json", archiveTags);
            AddJson("data/memberships.json", memberships);
            AddJson("data/candidates.json", decisions);
            AddJson("data/remoteSuggestions.json", archiveSuggestions);

            foreach (var (entry, source) in pdfEntries)
            {
                AddBytes(entry, await File.ReadAllBytesAsync(source, ct).ConfigureAwait(false));
            }

            AddJson("manifest.json", new DzManifest
            {
                FormatVersion = DzArchiveFormat.FormatVersion,
                Application = "DraftZero",
                ExportedByVersion = "0.2.0",
                ExportedAt = DateTime.UtcNow.ToString("o"),
                Files = files.OrderBy(f => f.Path, StringComparer.Ordinal).ToList(),
                Counts = counts,
            });
        }

        if (File.Exists(destination)) File.Delete(destination);
        File.Move(tempPath, destination);
        var size = new FileInfo(destination).Length;
        progress?.Invoke("导出完成。");
        return new ExportResult(destination, size);
    }
}
