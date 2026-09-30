using System.Text;
using System.Text.Json;
using DraftZero.Core;
using Xunit;

namespace DraftZero.Core.Tests;

/// <summary>合同测试：DeepSeek 提供方（注入网络层）与远程建议存储（R-010 / W-008）。</summary>
public sealed class DeepSeekTests
{
    private sealed class FakeFetcher : IHttpFetcher
    {
        private readonly Func<HttpRequestMessage, HttpResult> _handler;
        public List<string> Bodies { get; } = [];
        public FakeFetcher(Func<HttpRequestMessage, HttpResult> handler) => _handler = handler;
        public async Task<HttpResult> SendAsync(HttpRequestMessage request)
        {
            if (request.Content is not null)
            {
                Bodies.Add(await request.Content.ReadAsStringAsync());
            }
            return _handler(request);
        }
    }

    private static HttpResult Json(int code, string body) =>
        new(code, new Dictionary<string, string> { ["Content-Type"] = "application/json" },
            Encoding.UTF8.GetBytes(body));

    private static readonly string OkResponse = """
        {"choices":[{"message":{"content":"```json\n{\"groups\":[{\"draft_ids\":[0,1],\"reason\":\"主题相同\",\"citations\":[{\"draft_index\":0,\"quote\":\"基准测试评分口径\"},{\"draft_index\":1,\"quote\":\"编造的引用内容\"}]}]}\n```"}}]}
        """;

    // S-32c：引用校验——编造引用被丢弃；有效引用保留
    [Fact]
    public async Task Analyze_ValidatesCitations()
    {
        var fetcher = new FakeFetcher(_ => Json(200, OkResponse));
        var provider = new DeepSeekProvider("sk-test", fetcher: fetcher);
        var drafts = new List<(Guid, string, string)>
        {
            (Guid.NewGuid(), "甲", "讨论基准测试评分口径的正文。"),
            (Guid.NewGuid(), "乙", "另一段正文。"),
        };
        var (proposals, notice) = await provider.AnalyzeProjectCandidatesAsync(drafts);
        var proposal = Assert.Single(proposals);
        Assert.Equal(2, proposal.DraftIds.Count);
        var citation = Assert.Single(proposal.Citations);
        Assert.Equal(drafts[0].Item1, citation.DraftId);
        Assert.Equal("基准测试评分口径", citation.Quote);
        Assert.Null(notice);
    }

    // 截断：per-draft 1500 / 总 12000 预算（R-010 notice）
    [Fact]
    public async Task Analyze_TruncationNotice()
    {
        string? sent = null;
        var fetcher = new FakeFetcher(req =>
        {
            sent = req.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
            return Json(200, """{"choices":[{"message":{"content":"{\"groups\":[]}"}}]}""");
        });
        var provider = new DeepSeekProvider("sk-test", fetcher: fetcher);
        var longText = new string('长', 2000);
        var drafts = new List<(Guid, string, string)>
        {
            (Guid.NewGuid(), "甲", longText),
            (Guid.NewGuid(), "乙", "短文本。"),
        };
        var (proposals, notice) = await provider.AnalyzeProjectCandidatesAsync(drafts);
        Assert.Empty(proposals);
        Assert.NotNull(notice);
        Assert.Contains("1500", notice);
        // 只发送前 1500 字
        Assert.DoesNotContain(new string('长', 1600), sent);
    }

    [Fact]
    public async Task Analyze_SingleDraftSkipped()
    {
        var fetcher = new FakeFetcher(_ => throw new InvalidOperationException("不应发起请求"));
        var provider = new DeepSeekProvider("sk-test", fetcher: fetcher);
        var (proposals, notice) = await provider.AnalyzeProjectCandidatesAsync(
            [(Guid.NewGuid(), "单", "一份草稿。")]);
        Assert.Empty(proposals);
        Assert.Null(notice);
    }

    // S-32b：错误映射 401/402/429/5xx
    [Theory]
    [InlineData(401, "API Key 无效")]
    [InlineData(402, "余额不足")]
    [InlineData(429, "限流")]
    [InlineData(500, "远程服务出错")]
    public async Task Analyze_ErrorMapping(int code, string expectedFragment)
    {
        var fetcher = new FakeFetcher(_ => Json(code, "{}"));
        var provider = new DeepSeekProvider("sk-test", fetcher: fetcher);
        var drafts = new List<(Guid, string, string)>
        {
            (Guid.NewGuid(), "甲", "正文甲，足够长。"),
            (Guid.NewGuid(), "乙", "正文乙，足够长。"),
        };
        var ex = await Assert.ThrowsAsync<RemoteAnalysisException>(
            () => provider.AnalyzeProjectCandidatesAsync(drafts));
        Assert.Contains(expectedFragment, ex.Message);
    }

    // 引用匹配规则：归一化子串、≥8 字、前缀回退
    [Fact]
    public void QuoteMatches_Rules()
    {
        Assert.True(DeepSeekProvider.QuoteMatches("基准测试评分口径", "讨论基准测试评分口径的正文。"));
        Assert.True(DeepSeekProvider.QuoteMatches("基准测试评分口！径，", "讨论基准测试评分口径的正文。"), "归一化去标点");
        Assert.False(DeepSeekProvider.QuoteMatches("短引用", "讨论基准测试评分口径的正文。"), "过短无证据价值");
        Assert.False(DeepSeekProvider.QuoteMatches("完全不同的引用内容在这里", "讨论基准测试评分口径的正文。"));
        // 前缀回退：引用前 20 个归一化字符在原文中出现即认可（模型截短引文的兜底）
        Assert.False(DeepSeekProvider.QuoteMatches("基准测试评分口径吗", "讨论基准测试评分口径的正文。"), "短于 20 且非子串 → false");
        Assert.True(DeepSeekProvider.QuoteMatches(
            "讨论基准测试评分口径的正文以及后续补充说明内容然后自由发挥补足长度超过二十个归一化字符为止",
            "讨论基准测试评分口径的正文，以及后续补充说明内容。"), "前缀 20 字命中原文 → true");
    }

    // 围栏剥离与坏响应
    [Fact]
    public void ParseGroupsPayload_StripsFences()
    {
        var payload = DeepSeekProvider.ParseGroupsPayload(
            "```json\n{\"groups\":[{\"draft_ids\":[0,1],\"reason\":\"r\"}]}\n```");
        Assert.Single(payload.Groups!);
        var ex = Assert.Throws<RemoteAnalysisException>(
            () => DeepSeekProvider.ParseGroupsPayload("not json"));
        Assert.Contains("无法解析", ex.Message);
    }
}

/// <summary>
/// 合同测试：.dzarchive 导入（W-011 / 计划 §3）。
/// fixture `sample.dzarchive` 由 Mac Swift 导出器测试生成（跨平台契约）。
/// </summary>
public sealed class DzArchiveImportTests : IDisposable
{
    private readonly string _root;

    public DzArchiveImportTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "dz-mig-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private string FixturePath
    {
        get
        {
            var candidates = new[]
            {
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "migration", "sample.dzarchive"),
                Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "tests", "fixtures", "migration", "sample.dzarchive"),
            };
            foreach (var c in candidates)
            {
                if (File.Exists(c)) return c;
            }
            throw new FileNotFoundException("缺少迁移 fixture（由 Mac 导出测试生成）");
        }
    }

    private AppDatabase NewDb()
    {
        var db = new AppDatabase(Path.Combine(_root, "ws-" + Guid.NewGuid().ToString("N") + ".sqlite"));
        return db;
    }

    // M-01：计数对账；M-03 PDF 重绑；裁决与建议保留
    [Fact]
    public async Task Import_EmptyWorkspace_PreservesCountsAndContent()
    {
        await using var db = NewDb();
        var counts = await WorkspaceImporter.ImportAsync(db, FixturePath);
        Assert.Equal(5, counts.Drafts);
        Assert.Equal(1, counts.Projects);

        // 导入后的库可被 AppDatabase 正常打开（AppDatabase 构造迁移是幂等的）。
        var dbPath = db.DatabasePath;
        await db.DisposeAsync();
        var reopened = new AppDatabase(dbPath);
        var drafts = await reopened.DraftsAsync();
        Assert.Equal(5, drafts.Count);

        // 抽样正文逐字一致（M-02）
        var baseDraft = Assert.Single(drafts, d => d.Title == "基准测试想法");
        Assert.Contains("讨论任务集与评分口径。更新内容。", baseDraft.Content);

        // 版本计数与内容（含编辑版本与拆分产生的新稿）
        var versions = await reopened.VersionsAsync(baseDraft.Id);
        Assert.Equal(2, versions.Count);
        Assert.Contains(versions, v => v.Origin == VersionOrigin.AutoSave);

        // PDF 快照重绑到工作区 snapshots 目录（M-03）
        var pdfDraft = Assert.Single(drafts, d => d.SourceType == SourceType.Pdf);
        Assert.NotNull(pdfDraft.SnapshotFileURL);
        Assert.StartsWith(Path.GetDirectoryName(dbPath)!, pdfDraft.SnapshotFileURL);
        Assert.True(File.Exists(pdfDraft.SnapshotFileURL!), "PDF 快照应写入 Windows 工作区");
        Assert.DoesNotContain("/Users/", pdfDraft.SnapshotFileURL, StringComparison.OrdinalIgnoreCase);

        // 项目、标签、状态、成员（M-01 续）
        var projects = await reopened.ProjectsAsync();
        var project = Assert.Single(projects);
        Assert.Equal("评测计划", project.Name);
        Assert.Equal(ProjectStatus.Todo, project.Status);
        Assert.Single(await reopened.TagsOnProjectAsync(project.Id));
        Assert.Single(await reopened.DraftsInProjectAsync(project.Id));
        Assert.Single(await reopened.ProjectsContainingAsync(baseDraft.Id));

        // 拆分关系保留（M-01 续）
        var relations = await reopened.RelationsAsync(baseDraft.Id);
        Assert.Contains(relations, r => r.Type == RelationType.Split);

        // 用户裁决保留（抑制规则依赖）：rejected 行以原状态入库
        var rejected = await reopened.WriteAsync(conn => Task.FromResult(
            Db.ReadRows(conn, "SELECT count(*) AS n FROM candidatePair WHERE status='rejected'")));
        Assert.Equal(1, Db.Int(rejected[0], "n"));

        // 可展示的远程建议保留
        var suggestions = await reopened.PendingRemoteSuggestionsAsync();
        Assert.Single(suggestions);
        Assert.Equal("deepseek", suggestions[0].Provider);
        Assert.Equal(2, suggestions[0].DraftIds.Count);
        Assert.Single(suggestions[0].Citations);
        Assert.Contains("基准测试", suggestions[0].Citations[0].Quote);

        await reopened.DisposeAsync();
    }

    // M-05：非空工作区拒绝导入
    [Fact]
    public async Task Import_RejectsNonEmptyWorkspace()
    {
        await using var db = NewDb();
        await db.CreateManualDraftAsync("已有", "已有内容，工作区非空。");
        var before = await db.DraftsAsync();
        var ex = await Assert.ThrowsAsync<DzArchiveException>(() => WorkspaceImporter.ImportAsync(db, FixturePath));
        Assert.Contains("空工作区", ex.Message);
        // 零部分写入：原草稿仍在，无新行
        var after = await db.DraftsAsync();
        Assert.Equal(before.Count, after.Count);
        Assert.Equal(before[0].Id, after[0].Id);
    }

    // M-06：失败零部分写入（损坏档案不产生任何行）
    [Fact]
    public async Task Import_TamperedArchive_FailsCleanly()
    {
        var tampered = Path.Combine(_root, "tampered.dzarchive");
        var bytes = await File.ReadAllBytesAsync(FixturePath);
        // 翻转数据文件中部一个字节（破坏 SHA 校验）
        var mid = bytes.Length / 2;
        bytes[mid] ^= 0xFF;
        await File.WriteAllBytesAsync(tampered, bytes);

        await using var db = NewDb();
        await Assert.ThrowsAsync<DzArchiveException>(() => WorkspaceImporter.ImportAsync(db, tampered));
        var isEmpty = WorkspaceImporter.IsWorkspaceEmpty(db);
        Assert.True(isEmpty, "失败后主库必须仍是空库（零部分写入）");
    }

    [Fact]
    public async Task Import_TraversalPath_Rejected()
    {
        // 手工构造带 ../ 的档案：manifest 合法但路径越级。
        var evil = Path.Combine(_root, "evil.dzarchive");
        using (var zip = System.IO.Compression.ZipFile.Open(evil, System.IO.Compression.ZipArchiveMode.Create))
        {
            var entry = zip.CreateEntry("../outside.json");
            await using var stream = entry.Open();
            var payload = Encoding.UTF8.GetBytes("{}");
            await stream.WriteAsync(payload);
        }
        await using var db = NewDb();
        var ex = await Assert.ThrowsAsync<DzArchiveException>(() => DzArchiveReader.ReadAsync(evil));
        Assert.Contains("越级", ex.Message);
    }

    [Fact]
    public async Task Import_DuplicateUuid_Rejected()
    {
        var evil = Path.Combine(_root, "dup.dzarchive");
        using (var zip = System.IO.Compression.ZipFile.Open(evil, System.IO.Compression.ZipArchiveMode.Create))
        {
            var draftsJson = """[{"id":"11111111-1111-1111-1111-111111111111","title":"甲","content":"甲","isEditable":true,"hasExtractableText":true,"sourceType":"manual","importedAt":"2026-09-30T00:00:00Z"},{"id":"11111111-1111-1111-1111-111111111111","title":"乙","content":"乙","isEditable":true,"hasExtractableText":true,"sourceType":"manual","importedAt":"2026-09-30T00:00:00Z"}]""";
            foreach (var (path, data) in new Dictionary<string, string>
            {
                ["data/drafts.json"] = draftsJson,
                ["data/versions.json"] = "[]",
                ["data/relations.json"] = "[]",
                ["data/projects.json"] = "[]",
                ["data/tags.json"] = "{\"tags\":[],\"memberships\":[]}",
                ["data/memberships.json"] = "[]",
                ["data/candidates.json"] = "[]",
                ["data/remoteSuggestions.json"] = "[]",
                ["manifest.json"] = """{"formatVersion":1,"application":"DraftZero","exportedByVersion":"0.2.0","exportedAt":"2026-09-30T00:00:00Z","files":[],"counts":{"drafts":2,"versions":0,"projects":0,"memberships":0,"relations":0,"tags":0,"projectTags":0,"candidateDecisions":0,"remoteSuggestions":0,"pdfSnapshots":0}}""",
            })
            {
                var entry = zip.CreateEntry(path);
                await using var stream = entry.Open();
                var payload = Encoding.UTF8.GetBytes(data);
                await stream.WriteAsync(payload);
            }
        }
        await using var db = NewDb();
        var ex = await Assert.ThrowsAsync<DzArchiveException>(() => WorkspaceImporter.ImportAsync(db, evil));
        Assert.Contains("重复", ex.Message);
    }
}
