using DraftZero.Core;
using Xunit;

namespace DraftZero.Core.Tests;

/// <summary>合同测试：Windows 工作区导出（D-002 双向迁移）与导出→导入回环。</summary>
public sealed class WorkspaceExportTests : IDisposable
{
    private readonly string _root;

    public WorkspaceExportTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "dz-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private async Task<AppDatabase> SeedWorkspaceAsync(string name)
    {
        var snapshots = Path.Combine(_root, name + "-snapshots");
        Directory.CreateDirectory(snapshots);
        var db = new AppDatabase(Path.Combine(_root, name + ".sqlite"), snapshots);

        var a = await db.CreateManualDraftAsync("基准测试想法", "# 基准测试\n\n讨论任务集与评分口径。");
        var b = await db.CreateManualDraftAsync("无关草稿", "周末烘焙计划：面包与蛋糕。");
        var project = await db.CreateProjectAsync("评测计划");
        await db.AddDraftToProjectAsync(a.Id, project.Id);
        await db.AddTagToProjectAsync("测试", project.Id);
        await db.SetProjectStatusAsync(project.Id, ProjectStatus.Todo);

        var pdfDraft = new Draft
        {
            Title = "spec", Content = "PDF 快照正文。", IsEditable = false,
            HasExtractableText = true, SourceType = SourceType.Pdf, SourceLabel = "spec.pdf",
        };
        var pdfPath = Path.Combine(snapshots, $"{Guid.NewGuid():N}.pdf");
        await File.WriteAllBytesAsync(pdfPath, "%PDF-1.4\n%test"u8.ToArray());
        pdfDraft.SnapshotFileURL = pdfPath;
        await db.InsertDraftAsync(pdfDraft, initialVersion: true);

        var decision = new CandidatePair
        {
            DraftA = a.Id, DraftB = b.Id, Kind = CandidateKind.Lead, Score = 0.5,
            Status = CandidateStatus.Rejected,
            FingerprintA = TextReading.Fingerprint("x"), FingerprintB = TextReading.Fingerprint("y"),
        };
        await db.WriteAsync(conn =>
        {
            Db.Exec(conn, """
                INSERT INTO candidatePair (id,draftA,draftB,kind,score,evidence,status,fingerprintA,fingerprintB,lastDecision,createdAt,decidedAt)
                VALUES (@id,@a,@b,'lead',0.5,NULL,'rejected',@fa,@fb,NULL,@now,@now)
                """,
                Db.P("@id", Db.Uid(decision.Id)),
                Db.P("@a", Db.Uid(decision.DraftA)), Db.P("@b", Db.Uid(decision.DraftB)),
                Db.P("@fa", decision.FingerprintA), Db.P("@fb", decision.FingerprintB),
                Db.P("@now", Db.Fmt(DateTime.UtcNow)));
            return Task.CompletedTask;
        });
        return db;
    }

    [Fact]
    public async Task Export_RoundTrip_PreservesCountsAndContent()
    {
        await using var db = await SeedWorkspaceAsync("roundtrip");
        var destination = Path.Combine(_root, "out.dzarchive");
        var result = await WorkspaceExporter.ExportAsync(db, destination);
        Assert.True(File.Exists(destination));
        Assert.Equal(new FileInfo(destination).Length, result.SizeBytes);
        Assert.True(result.SizeBytes > 100);

        // 导入到全新空库（ImportAsync 成功时会释放传入库并替换文件 → 重开后断言）
        var importPath = Path.Combine(_root, "import.sqlite");
        var importSnapshots = Path.Combine(_root, "import-snapshots");
        Directory.CreateDirectory(importSnapshots);
        var importDb = new AppDatabase(importPath, importSnapshots);
        var counts = await WorkspaceImporter.ImportAsync(importDb, destination);

        Assert.Equal(3, counts.Drafts);           // 2 手稿 + 1 PDF
        Assert.Equal(1, counts.Projects);
        Assert.Equal(1, counts.Tags);
        Assert.Equal(1, counts.PdfSnapshots);
        Assert.Equal(1, counts.CandidateDecisions);

        var reopened = new AppDatabase(importPath, importSnapshots);
        try
        {
            // 抽样正文与 PDF 重绑
            var drafts = await reopened.DraftsAsync();
            var baseDraft = Assert.Single(drafts, d => d.Title == "基准测试想法");
            Assert.Contains("讨论任务集与评分口径", baseDraft.Content);
            var pdf = Assert.Single(drafts, d => d.SourceType == SourceType.Pdf);
            Assert.True(File.Exists(pdf.SnapshotFileURL));
            Assert.StartsWith(importSnapshots, pdf.SnapshotFileURL);

            // 裁决保留（抑制规则依赖）
            var rejected = await reopened.WriteAsync(conn => Task.FromResult(
                Db.Long(conn, "SELECT count(*) FROM candidatePair WHERE status='rejected'")));
            Assert.Equal(1, rejected);
        }
        finally
        {
            await reopened.DisposeAsync();
        }
    }

    [Fact]
    public async Task Export_DoesNotMutateSource()
    {
        await using var db = await SeedWorkspaceAsync("nomutate");
        var before = await db.DraftsAsync();
        var destination = Path.Combine(_root, "nomutate.dzarchive");
        await WorkspaceExporter.ExportAsync(db, destination);
        var after = await db.DraftsAsync();
        Assert.Equal(before.Select(d => d.Id), after.Select(d => d.Id));
        Assert.Equal(before.Select(d => d.Content), after.Select(d => d.Content));
    }

    /// <summary>生成跨平台 fixture：Windows 导出的档案，供 Mac 导入测试使用。</summary>
    [Fact]
    public async Task Export_GenerateWindowsFixture()
    {
        await using var db = await SeedWorkspaceAsync("fixture");
        var destination = Path.Combine(_root, "sample-win.dzarchive");
        await WorkspaceExporter.ExportAsync(db, destination);
        var fixtureTarget = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "..", "tests", "DraftZero.Core.Tests", "Fixtures", "migration", "sample-win.dzarchive"));
        Directory.CreateDirectory(Path.GetDirectoryName(fixtureTarget)!);
        File.Copy(destination, fixtureTarget, overwrite: true);
        Assert.True(File.Exists(fixtureTarget));
    }
}
