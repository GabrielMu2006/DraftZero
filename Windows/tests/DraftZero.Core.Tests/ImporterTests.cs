using System.Text;
using DraftZero.Core;
using Xunit;

namespace DraftZero.Core.Tests;

/// <summary>合同测试：本地导入与网页/GitHub 导入（注入网络层，断网可跑）。</summary>
public sealed class ImporterTests : IDisposable
{
    private readonly AppDatabase _db;
    private readonly string _root;
    private readonly string _snapshots;

    public ImporterTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "dz-imp-" + Guid.NewGuid().ToString("N"));
        _snapshots = Path.Combine(_root, "snapshots");
        Directory.CreateDirectory(_snapshots);
        _db = new AppDatabase(Path.Combine(_root, "dz.sqlite"), _snapshots);
    }

    public void Dispose()
    {
        _db.DisposeAsync().AsTask().GetAwaiter().GetResult();
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private string WriteFile(string name, string content, Encoding? encoding = null)
    {
        var path = Path.Combine(_root, name);
        File.WriteAllBytes(path, (encoding ?? Encoding.UTF8).GetBytes(content));
        return path;
    }

    // S-01：多文件逐项结果；S-03：坏扩展名与空文本
    [Fact]
    public async Task ImportFiles_ReportsPerItem()
    {
        var good = WriteFile("a.md", "# 标题甲\n\n正文甲");
        var empty = WriteFile("empty.txt", "   \n  ");
        var bad = WriteFile("b.docx", "binary");
        var importer = new LocalFileImporter(_db, _snapshots);
        var results = await importer.ImportFilesAsync([good, empty, bad]);

        Assert.IsType<ImportOutcome.Success>(results[0].Outcome);
        var failure = Assert.IsType<ImportOutcome.Failure>(results[1].Outcome);
        Assert.Contains("没有可读取的正文", failure.Reason);
        var failure2 = Assert.IsType<ImportOutcome.Failure>(results[2].Outcome);
        Assert.Contains("不支持的文件类型", failure2.Reason);
        Assert.Single(await _db.DraftsAsync());
    }

    // S-01b：原文件字节不变
    [Fact]
    public async Task ImportTextFile_OriginalUnchanged()
    {
        var content = "# 标题\n\n正文内容";
        var path = WriteFile("note.md", content);
        var before = File.ReadAllBytes(path);
        var importer = new LocalFileImporter(_db, _snapshots);
        var outcome = await importer.ImportFileAsync(path);
        Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    // 标题提取：Markdown 一级标题优先，否则首非空行；80 字截断
    [Theory]
    [InlineData("# 大标题\n\n正文", "大标题")]
    [InlineData("## 二级\n正文", "二级")]
    [InlineData("首行即标题\n第二行", "首行即标题")]
    public void ExtractTitle_Rules(string text, string expected)
    {
        Assert.Equal(expected, TextReading.ExtractTitle(text, "回退"));
    }

    // GB18030 旧文件读取
    [Fact]
    public async Task ReadText_Gb18030Fallback()
    {
        var content = "这是 GB18030 编码的旧文件内容，包含中文字符。";
        var path = WriteFile("old.txt", content, Encoding.GetEncoding("GB18030"));
        var importer = new LocalFileImporter(_db, _snapshots);
        var outcome = await importer.ImportFileAsync(path);
        var success = Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.Equal(content, success.Draft.Content);
    }

    // S-06：重复来源（同路径与同指纹）
    [Fact]
    public async Task ImportFile_DuplicateDetection()
    {
        var path1 = WriteFile("note-a.md", "重复内容测试，完全相同的正文。");
        var path2 = WriteFile("note-b.md", "重复内容测试，完全相同的正文。");
        var importer = new LocalFileImporter(_db, _snapshots);
        Assert.IsType<ImportOutcome.Success>(await importer.ImportFileAsync(path1));
        // 同路径重复
        var dup1 = Assert.IsType<ImportOutcome.Duplicate>(await importer.ImportFileAsync(path1));
        Assert.NotNull(dup1.Existing.Fingerprint);
        // 文件名不同但内容相同 → 指纹命中
        var dup2 = Assert.IsType<ImportOutcome.Duplicate>(await importer.ImportFileAsync(path2));
        Assert.Equal(dup1.Existing.Id, dup2.Existing.Id);
        // 另存新快照
        var again = await importer.ImportFileAsync(path2, allowDuplicate: true);
        Assert.IsType<ImportOutcome.Success>(again);
        Assert.Equal(2, (await _db.DraftsAsync()).Count);
    }

    // S-05：PDF 提取与扫描版标记（PdfPig）
    private static string FixturePdf(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", "pdf", name);

    [Fact]
    public async Task ImportPdf_ExtractableAndMarked()
    {
        var pdfPath = FixturePdf("extractable.pdf");
        var importer = new LocalFileImporter(_db, _snapshots);
        var outcome = await importer.ImportFileAsync(pdfPath);
        var success = Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.True(success.Draft.HasExtractableText);
        Assert.Contains("extractable body text", success.Draft.Content);
        Assert.False(success.Draft.IsEditable);
        Assert.NotNull(success.Draft.SnapshotFileURL);
        Assert.True(File.Exists(success.Draft.SnapshotFileURL!));
        // 快照名重绑到工作区 snapshots 目录
        Assert.StartsWith(_snapshots, success.Draft.SnapshotFileURL);
    }

    [Fact]
    public async Task ImportPdf_ScannedMarkedNoText()
    {
        var pdfPath = FixturePdf("scanned.pdf");
        var importer = new LocalFileImporter(_db, _snapshots);
        var outcome = await importer.ImportFileAsync(pdfPath);
        var success = Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.False(success.Draft.HasExtractableText);
        Assert.Null(success.Draft.Content);
        Assert.Null(success.Draft.Fingerprint);
    }

    [Fact]
    public async Task ImportPdf_CorruptedFails()
    {
        var path = Path.Combine(_root, "broken.pdf");
        await File.WriteAllBytesAsync(path, "not a pdf at all"u8.ToArray());
        var importer = new LocalFileImporter(_db, _snapshots);
        var outcome = await importer.ImportFileAsync(path);
        var failure = Assert.IsType<ImportOutcome.Failure>(outcome);
        Assert.False(string.IsNullOrEmpty(failure.Reason));
    }

    // ---- 网页导入（注入 fetcher） ----

    private const string SampleHtml = """
        <html><head><title>测试页面 &amp; 说明</title><style>body{color:red}</style></head>
        <body>
        <nav>导航 导航</nav>
        <h1>主标题</h1>
        <p>这是第一段正文，包含足够多的中文字符来满足最小正文长度要求，用于网页快照导入测试。</p>
        <script>alert(1)</script>
        <footer>页脚信息</footer>
        </body></html>
        """;

    private sealed class FakeFetcher : IHttpFetcher
    {
        private readonly Func<HttpRequestMessage, HttpResult> _handler;
        public FakeFetcher(Func<HttpRequestMessage, HttpResult> handler) => _handler = handler;
        public List<HttpRequestMessage> Requests { get; } = [];
        public Task<HttpResult> SendAsync(HttpRequestMessage request)
        {
            Requests.Add(request);
            return Task.FromResult(_handler(request));
        }
    }

    private static HttpResult Html(int code, string body) => new(code,
        new Dictionary<string, string> { ["Content-Type"] = "text/html; charset=utf-8" },
        Encoding.UTF8.GetBytes(body));

    [Fact]
    public async Task WebImporter_ExtractsTextAndNormalizesAnchor()
    {
        var fetcher = new FakeFetcher(_ => Html(200, SampleHtml));
        var importer = new WebImporter(_db, fetcher);
        var outcome = await importer.ImportWebPageAsync(new Uri("https://example.com/post?a=1#section"));
        var success = Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.Equal("测试页面 & 说明", success.Draft.Title);
        Assert.DoesNotContain("alert(1)", success.Draft.Content);
        Assert.DoesNotContain("导航", success.Draft.Content);
        Assert.DoesNotContain("页脚", success.Draft.Content);
        Assert.Contains("第一段正文", success.Draft.Content);
        Assert.Equal("https://example.com/post?a=1", success.Draft.SourceLocation);
        Assert.Equal("example.com", success.Draft.SourceLabel);
        Assert.False(success.Draft.IsEditable);
        // 显式 User-Agent（Mac HTTPUserAgent 行为对齐）
        Assert.True(fetcher.Requests[0].Headers.Contains("User-Agent"));
    }

    [Fact]
    public async Task WebImporter_Errors()
    {
        var importer = new WebImporter(_db, new FakeFetcher(_ => Html(404, "nope")));
        var outcome = await importer.ImportWebPageAsync(new Uri("https://example.com/missing"));
        Assert.Contains("HTTP 404", Assert.IsType<ImportOutcome.Failure>(outcome).Reason);

        var binary = new WebImporter(_db, new FakeFetcher(_ => new HttpResult(200,
            new Dictionary<string, string> { ["Content-Type"] = "image/png" }, [1, 2, 3])));
        var notReadable = await binary.ImportWebPageAsync(new Uri("https://example.com/img.png"));
        Assert.Contains("不是可读取的网页", Assert.IsType<ImportOutcome.Failure>(notReadable).Reason);

        var empty = new WebImporter(_db, new FakeFetcher(_ => Html(200, "<html><body>短</body></html>")));
        var noBody = await empty.ImportWebPageAsync(new Uri("https://example.com/empty"));
        Assert.Contains("无法提取正文", Assert.IsType<ImportOutcome.Failure>(noBody).Reason);

        var network = new WebImporter(_db, new FakeFetcher(_ => throw new HttpRequestException("DNS")));
        var unreachable = await network.ImportWebPageAsync(new Uri("https://nonexistent.invalid/"));
        Assert.Contains("网络错误", Assert.IsType<ImportOutcome.Failure>(unreachable).Reason);
    }

    // ---- GitHub 链接解析 ----

    [Theory]
    [InlineData("https://github.com/owner/repo", "Repo", "owner", "repo", null, null)]
    [InlineData("https://github.com/owner/repo.git", "Repo", "owner", "repo", null, null)]
    [InlineData("https://github.com/owner/repo/tree/main/docs", "Repo", "owner", "repo", "main", "docs")]
    [InlineData("https://github.com/owner/repo/blob/main/README.md", "File", "owner", "repo", "main", "README.md")]
    public void GitHubLinkParser_Parses(string raw, string kind, string owner, string repo, string? refName, string? path)
    {
        var parsed = GitHubLinkParser.Parse(raw);
        Assert.NotNull(parsed);
        Assert.Equal(kind, parsed!.Kind.ToString());
        Assert.Equal(owner, parsed.Owner);
        Assert.Equal(repo, parsed.Repo);
        Assert.Equal(refName, parsed.RefName);
        Assert.Equal(path, parsed.Path);
    }

    [Theory]
    [InlineData("https://gitlab.com/owner/repo")]
    [InlineData("https://github.com/owner")]
    [InlineData("not a url")]
    public void GitHubLinkParser_Rejects(string raw)
    {
        Assert.Null(GitHubLinkParser.Parse(raw));
    }

    // S-06b/c/d：仓库勾选导入、单文件、取消零导入、错误映射
    [Fact]
    public async Task GitHubImporter_RepoBatchAndSingleFile()
    {
        var rawContent = "# Repo 文档\n\n仓库文件正文内容。";
        var fetcher = new FakeFetcher(req =>
        {
            var url = req.RequestUri!.ToString();
            if (url.Contains("/git/trees/"))
            {
                var json = """
                    {"sha":"tree-sha-1","truncated":false,"tree":[
                        {"path":"README.md","type":"blob","sha":"blob1","size":100},
                        {"path":"img/logo.png","type":"blob","sha":"blob2","size":9000}]}
                    """;
                return new HttpResult(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes(json));
            }
            if (url.StartsWith("https://raw.githubusercontent.com/"))
            {
                // 不同路径给不同内容：同内容会按生产指纹规则判重（与 Mac 一致）
                var body = url.EndsWith("docs/intro.md") ? "# 入门文档\n\n独立路径的独立内容。" : rawContent;
                return new HttpResult(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes(body));
            }
            if (url.Contains("/commits?path="))
            {
                return new HttpResult(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("""[{"sha":"commit-9"}]"""));
            }
            return new HttpResult(404, new Dictionary<string, string>(), []);
        });

        var client = new GitHubClient(fetcher);
        var (treeSha, entries, truncated) = await client.ListTreeAsync("owner", "repo", "main");
        Assert.False(truncated);
        Assert.Equal(2, entries.Count);

        // 勾选列表 → 只导入所选（模拟 UI 勾选 README.md）
        var importer = new GitHubImporter(_db, _snapshots, client);
        var request = new GitHubImportRequest
        {
            Owner = "owner", Repo = "repo", Branch = "main", TreeSha = treeSha,
            Path = "README.md", BlobSha = "blob1",
        };
        var outcome = await importer.ImportFileAsync(request);
        var success = Assert.IsType<ImportOutcome.Success>(outcome);
        Assert.Equal("https://github.com/owner/repo/blob/main/README.md", success.Draft.SourceLocation);
        Assert.Equal("owner/repo：README.md", success.Draft.SourceLabel);
        Assert.Equal("tree-sha-1", success.Draft.SourceVersionSha);
        Assert.False(success.Draft.IsEditable);

        // 单文件：版本取最近 commit SHA（用不同路径避免命中上面的重复检测）
        var parsed = GitHubLinkParser.Parse("https://github.com/owner/repo/blob/main/docs/intro.md");
        var single = await importer.ImportSingleFileAsync(parsed!);
        var singleSuccess = Assert.IsType<ImportOutcome.Success>(single);
        Assert.Equal("commit-9", singleSuccess.Draft.SourceVersionSha);
        Assert.Equal("https://github.com/owner/repo/blob/main/docs/intro.md", singleSuccess.Draft.SourceLocation);
    }

    [Fact]
    public async Task GitHubImporter_ErrorMapping()
    {
        var fetcher = new FakeFetcher(req => new HttpResult(403,
            new Dictionary<string, string> { ["X-RateLimit-Remaining"] = "0" }, []));
        var client = new GitHubClient(fetcher);
        await Assert.ThrowsAsync<GitHubClient.GitHubException>(
            () => client.DefaultBranchAsync("o", "r"));

        var importer = new GitHubImporter(_db, _snapshots, client);
        var parsed = GitHubLinkParser.Parse("https://github.com/o/r/blob/main/f.md")!;
        var outcome = await importer.ImportSingleFileAsync(parsed);
        Assert.IsType<ImportOutcome.Failure>(outcome);
    }

    // LineDiff（版本对比）
    [Fact]
    public void LineDiff_BasicOps()
    {
        var ops = LineDiff.Diff("a\nb\nc", "a\nx\nc");
        Assert.Contains(ops, o => o.Kind == LineDiff.OpKind.Removed && o.Text == "b");
        Assert.Contains(ops, o => o.Kind == LineDiff.OpKind.Added && o.Text == "x");
        Assert.True(LineDiff.HasChanges(ops));
        Assert.False(LineDiff.HasChanges(LineDiff.Diff("same", "same")));
        // 超长降级：全部标记替换而不丢内容
        var big1 = string.Join("\n", Enumerable.Range(0, 2500).Select(i => $"old-{i}"));
        var big2 = string.Join("\n", Enumerable.Range(0, 2500).Select(i => $"new-{i}"));
        var degraded = LineDiff.Diff(big1, big2);
        Assert.Equal(5000, degraded.Count);
    }

    // AutoVersioner：静默期 + flush（R-006，注入时钟）
    [Fact]
    public async Task AutoVersioner_IdleThenFlush()
    {
        var persisted = new List<(Guid, string)>();
        var clock = new Microsoft.Extensions.Time.Testing.FakeTimeProvider();
        var versioner = new AutoVersioner((id, text) =>
        {
            persisted.Add((id, text));
            return Task.CompletedTask;
        }, TimeSpan.FromSeconds(60), clock);

        var draftId = Guid.NewGuid();
        versioner.ContentChanged(draftId, "草稿第一版");
        versioner.ContentChanged(draftId, "草稿第二版"); // 重置计时，不产生中间版本
        clock.Advance(TimeSpan.FromSeconds(59));
        Assert.Empty(persisted);
        clock.Advance(TimeSpan.FromSeconds(1));
        await Task.Delay(50);
        var entry = Assert.Single(persisted);
        Assert.Equal("草稿第二版", entry.Item2);

        // flush：离页立即结算
        versioner.ContentChanged(draftId, "草稿第三版");
        await versioner.FlushAsync(draftId);
        Assert.Equal(2, persisted.Count);
        Assert.Equal("草稿第三版", persisted[1].Item2);
    }
}
