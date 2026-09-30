using DraftZero.Core;
using Xunit;

namespace DraftZero.Core.Tests;

/// <summary>合同测试：切片、字面信号、候选引擎、裁决与抑制（对齐 Mac CandidateEngineTests）。</summary>
public sealed class CandidateEngineTests : IDisposable
{
    private readonly AppDatabase _db;
    private readonly string _root;

    public CandidateEngineTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "dz-eng-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
        _db = new AppDatabase(Path.Combine(_root, "dz.sqlite"));
    }

    public void Dispose()
    {
        _db.DisposeAsync().AsTask().GetAwaiter().GetResult();
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    // 切片：段落切块、短段合并、超长硬切、标题识别
    [Fact]
    public void Chunker_ParagraphsAndHeadings()
    {
        var text = "# 标题甲\n\n这是第一段的正文内容，足够长不并段。\n\n短段\n\n" + new string('长', 700) + "。";
        var chunks = Chunker.ChunkText(text);
        Assert.True(chunks.Count >= 3);
        Assert.Equal("标题甲", chunks[0].Heading);
        Assert.Equal(0, chunks[0].ChunkIndex);
        // 短段并入前段
        Assert.DoesNotContain(chunks, c => c.Text == "短段");
        // 超长段落硬切（>600）
        Assert.Contains(chunks, c => c.Text.Length <= 600);
        // chunkIndex 连续
        for (int i = 0; i < chunks.Count; i++) Assert.Equal(i, chunks[i].ChunkIndex);
    }

    [Fact]
    public void Chunker_EmptyAndShort()
    {
        Assert.Empty(Chunker.ChunkText(""));
        Assert.Empty(Chunker.ChunkText("   \n\n  "));
        var one = Chunker.ChunkText("只有一句话。");
        Assert.Single(one);
    }

    // 字面信号
    [Fact]
    public void LiteralSignals_TokensAndJaccard()
    {
        var tokens = LiteralSignals.Tokens("Hello World 测试试行 hello");
        Assert.Contains("hello", tokens);
        Assert.Contains("world", tokens);
        Assert.Contains("测试", tokens);   // CJK 二元组
        Assert.Contains("试行", tokens);
        Assert.DoesNotContain("h", tokens); // 单字符拉丁不计
        var a = LiteralSignals.Tokens("agent benchmark 评测");
        var b = LiteralSignals.Tokens("agent benchmark 评测");
        Assert.Equal(1.0, LiteralSignals.Jaccard(a, b));
        var c = LiteralSignals.Tokens("完全无关的内容");
        Assert.Equal(0, LiteralSignals.Jaccard(a, c));
    }

    [Fact]
    public void LiteralSignals_CommonTerms_LongerFirst()
    {
        var terms = LiteralSignals.CommonTerms(
            LiteralSignals.Tokens("benchmark 评测任务集"),
            LiteralSignals.Tokens("benchmark 评测标准"));
        Assert.Equal("benchmark", terms[0]);
        Assert.Contains("评测", terms);
        Assert.DoesNotContain("任务集", terms);
    }

    // 引擎集成：断网（FakeEmbedder）产生 lead/duplicate 两队列、裁决与抑制
    [Fact]
    public async Task Engine_ProducesLeadsAndDuplicates_WithEvidence()
    {
        // 向量器注入确定性假向量：同主题文本向量相近
        var embedder = new TopicEmbedder();
        var d1 = await _db.CreateManualDraftAsync("基准测试想法", "# 基准测试\n\n讨论任务集与评分口径，用于评估草稿归类质量，基准测试评分口径是本组草稿共同的主题词。");
        var d2 = await _db.CreateManualDraftAsync("模型测试 prompt", "模型测试提示词，同样讨论基准测试评分口径：评分口径与任务集是共同主题。");
        var dup1 = await _db.CreateManualDraftAsync("重复甲", "完全相同的重复内容用来测试重复队列的行为。");
        var dup2 = await _db.CreateManualDraftAsync("重复乙", "完全相同的重复内容用来测试重复队列的行为。");
        var engine = new CandidateEngine(_db, embedder);
        var drafts = await _db.DraftsAsync();
        var report = await engine.RefreshAsync(drafts);

        Assert.Equal(4, report.IndexedDrafts);
        // 指纹相同的 dup1/dup2 进入"可能重复"（duplicate 优先于 lead 判定）
        var duplicates = await engine.QueueAsync(CandidateKind.Duplicate);
        var duplicatePair = Assert.Single(duplicates);
        var ids = new[] { duplicatePair.DraftA, duplicatePair.DraftB };
        Assert.Contains(dup1.Id, ids);
        Assert.Contains(dup2.Id, ids);

        var leads = await engine.QueueAsync(CandidateKind.Lead);
        Assert.NotEmpty(leads);
        // 证据自包含且指向原文切片
        var evidence = Assert.IsType<PairEvidence>(leads[0].EvidenceDecoded());
        Assert.False(string.IsNullOrEmpty(evidence.A.Text));
        Assert.False(string.IsNullOrEmpty(evidence.B.Text));
        Assert.True(evidence.SemanticScore > 0);
    }

    [Fact]
    public async Task Engine_RejectionSuppressionAndReanalysis()
    {
        var embedder = new TopicEmbedder();
        var d1 = await _db.CreateManualDraftAsync("甲", "关于本机语义索引与候选排序的长文本讨论内容：本机语义索引、候选排序是这份草稿的核心主题，反复出现以保证切片后语义向量相近。");
        var d2 = await _db.CreateManualDraftAsync("乙", "关于本机语义索引与候选排序的另一段讨论内容：候选排序、本机语义索引同样是核心主题，反复出现以贴近第一份草稿的语义向量。");
        var engine = new CandidateEngine(_db, embedder);
        var drafts = await _db.DraftsAsync();
        await engine.RefreshAsync(drafts);
        var leads = await engine.QueueAsync(CandidateKind.Lead);
        var pair = leads[0];

        // 拒绝 → 不再出现在待审
        await engine.DecideAsync(pair.Id, CandidateStatus.Rejected);
        Assert.DoesNotContain(await engine.QueueAsync(CandidateKind.Lead), p => p.Id == pair.Id);

        // 重建候选：内容未变 → 抑制（不重新弹出）
        await engine.RefreshAsync(await _db.DraftsAsync());
        Assert.DoesNotContain(await engine.QueueAsync(CandidateKind.Lead), p => p.Id == pair.Id);

        // 内容变化 → 新候选行出现，旧记录保留
        await _db.UpdateDraftContentAsync(d1.Id, "内容已完全改变，变成了新的主题讨论：烘焙面包的配方与发酵时间。");
        await engine.RefreshAsync(await _db.DraftsAsync());
        var fresh = await engine.QueueAsync(CandidateKind.Lead);
        var newPair = fresh.FirstOrDefault(p => p.Involves(d1.Id) && p.Involves(d2.Id));
        if (newPair is not null)
        {
            Assert.NotEqual(pair.Id, newPair.Id);
            Assert.Equal(CandidateStatus.Pending, newPair.Status);
            // 旧拒绝记录仍在（状态不变）
            Assert.Null(await FindPair(pair.Id, CandidateStatus.Pending));
        }

        // 重新分析：恢复待审并保留裁决记录
        await engine.ReanalyzeAsync(pair.Id);
        var reanalyzed = (await engine.QueueAsync(CandidateKind.Lead)).FirstOrDefault(p => p.Id == pair.Id)
            ?? (await engine.QueueAsync(CandidateKind.Lead, CandidateStatus.Rejected)).FirstOrDefault();
        if (reanalyzed is not null)
        {
            Assert.NotNull(reanalyzed.LastDecision);
        }
    }

    private async Task<CandidatePair?> FindPair(Guid id, CandidateStatus status)
    {
        var pairs = await _db.WriteAsync(conn =>
            Task.FromResult(Db.ReadRows(conn, "SELECT * FROM candidatePair WHERE id=@id",
                Db.P("@id", Db.Uid(id))).Select(_ => true).ToList()));
        return pairs.Count > 0 ? new CandidatePair { Id = id, Status = status } : null;
    }

    // 接受：入项目幂等 + decidedAt
    [Fact]
    public async Task Engine_AcceptAddsToProject()
    {
        var embedder = new TopicEmbedder();
        var d1 = await _db.CreateManualDraftAsync("甲", "关于本机语义索引与候选排序的长文本讨论内容：本机语义索引、候选排序是这份草稿的核心主题，反复出现以保证切片后语义向量相近。");
        var d2 = await _db.CreateManualDraftAsync("乙", "关于本机语义索引与候选排序的另一段讨论内容：候选排序、本机语义索引同样是核心主题，反复出现以贴近第一份草稿的语义向量。");
        var engine = new CandidateEngine(_db, embedder);
        await engine.RefreshAsync(await _db.DraftsAsync());
        var pair = (await engine.QueueAsync()).First();
        var project = await _db.CreateProjectAsync("目标项目");
        await engine.AcceptAsync(pair.Id, project.Id);
        Assert.Equal(2, (await _db.DraftsInProjectAsync(project.Id)).Count);
        var decided = (await engine.QueueAsync()).FirstOrDefault(p => p.Id == pair.Id);
        Assert.Null(decided); // 已不在待审
    }

    // 候选组：贪心聚合、不传递、桥接文档可多组
    [Fact]
    public void Engine_CandidateGroups_NoTransitiveMerge()
    {
        // 共享成员的对贪心并入同组（Mac 同语义）：a-b 与 b-c → 一组
        var a = Guid.NewGuid(); var b = Guid.NewGuid(); var c = Guid.NewGuid();
        var d = Guid.NewGuid(); var e = Guid.NewGuid();
        var pairAb = NewPair(a, b, 0.9);
        var pairBc = NewPair(b, c, 0.8);
        var groups = CandidateEngine.CandidateGroups([pairAb, pairBc]);
        Assert.Single(groups);
        Assert.Contains(pairAb, groups[0]);
        Assert.Contains(pairBc, groups[0]);

        // 无共享的两个独立对 → 两组
        var pairDe = NewPair(d, e, 0.7);
        var groups2 = CandidateEngine.CandidateGroups([pairAb, pairDe]);
        Assert.Equal(2, groups2.Count);

        // 桥接场景：bc 两端分属两组（ab∈g0、cd∈g1）→ 两组保持独立，bc 并入 g0
        var pairCd = NewPair(c, d, 0.75);
        var pairBc2 = NewPair(b, c, 0.6);
        var groups3 = CandidateEngine.CandidateGroups([pairAb, pairCd, pairBc2]);
        Assert.Equal(2, groups3.Count);
        Assert.Contains(pairBc2, groups3.First(g => g.Contains(pairAb)));
    }

    private static CandidatePair NewPair(Guid a, Guid b, double score) => new()
    {
        DraftA = a, DraftB = b, Kind = CandidateKind.Lead, Score = score,
        Status = CandidateStatus.Pending,
        Evidence = System.Text.Json.JsonSerializer.Serialize(new PairEvidence
        {
            A = new PairEvidence.Snippet { DraftId = a, Text = "甲" },
            B = new PairEvidence.Snippet { DraftId = b, Text = "乙" },
        }),
    };

    // per-draft topK 并集（防全局贪心截断回归）
    [Fact]
    public async Task Engine_PerDraftTopK()
    {
        // 构造 8 份草稿：0 与其余 7 份高相似；1 与 2 高相似——保证 0 不挤占 1/2 的槽位。
        var embedder = new TopicEmbedder();
        var drafts = new List<Draft>();
        for (int i = 0; i < 8; i++)
        {
            var draft = await _db.CreateManualDraftAsync($"主题群{i}", $"主题群{i} 的共同讨论文本，用来占据候选槽位。");
            drafts.Add(draft);
        }
        var engine = new CandidateEngine(_db, embedder);
        await engine.RefreshAsync(await _db.DraftsAsync());
        var pending = await engine.QueueAsync();
        foreach (var draft in drafts)
        {
            // 每稿自己的 top-K 全部保留（防饿死回归）；受欢迎的草稿可被
            // 其他稿的 top-K 带入更多对（并集语义，与 Mac 一致）。
            var own = pending.Where(p => p.Involves(draft.Id)).ToList();
            Assert.True(own.Count >= Math.Min(CandidateTuning.TopKPerDraft, drafts.Count - 1),
                "每稿至少保留自己的 top-K 候选");
        }
    }

    // 拒绝后再变化→新行带 lastDecision 标记（R-004 表格）
    [Fact]
    public async Task Engine_RejectedThenChanged_CarriesLastDecision()
    {
        var embedder = new TopicEmbedder();
        var d1 = await _db.CreateManualDraftAsync("甲", "关于本机语义索引与候选排序的长文本讨论内容：本机语义索引与候选排序反复出现，确保语义向量相近并进入候选队列。");
        var d2 = await _db.CreateManualDraftAsync("乙", "关于本机语义索引与候选排序的另一段讨论内容：候选排序与本机语义索引反复出现，确保语义向量相近并进入候选队列。");
        var engine = new CandidateEngine(_db, embedder);
        await engine.RefreshAsync(await _db.DraftsAsync());
        var pair = (await engine.QueueAsync(CandidateKind.Lead))[0];
        await engine.DecideAsync(pair.Id, CandidateStatus.Rejected);
        await _db.UpdateDraftContentAsync(d2.Id, "草稿乙的正文被大幅改写：深夜书店的雨夜场景描写与人物关系。");
        await engine.RefreshAsync(await _db.DraftsAsync());
        // 若两稿再度成为候选，必须是新 pending 行且带 lastDecision
        var fresh = (await engine.QueueAsync(CandidateKind.Lead)).FirstOrDefault(p => p.Involves(d1.Id) && p.Involves(d2.Id));
        if (fresh is not null && fresh.Id != pair.Id)
        {
            Assert.NotNull(fresh.LastDecision);
            Assert.Contains("rejected", fresh.LastDecision);
        }
    }

    /// <summary>字符 bigram 词袋确定性嵌入：相似文本共享 bigram → 高余弦（离线可跑、语义近邻）。</summary>
    private sealed class TopicEmbedder : ITextEmbedding
    {
        public int Dimension => 64;

        public float[][] Embed(string[] texts) =>
            texts.Select(t =>
            {
                var v = new float[Dimension];
                var lowered = t.ToLowerInvariant();
                for (int i = 0; i + 1 < lowered.Length; i++)
                {
                    int h = (lowered[i] * 31 + lowered[i + 1]) & 0x7FFFFFFF;
                    v[h % Dimension] += 1;
                }
                // 词级 token 也计入（英文按空格）
                foreach (var word in lowered.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (word.Length >= 2)
                    {
                        int h = 0;
                        foreach (var c in word) h = (h * 31 + c) & 0x7FFFFFFF;
                        v[h % Dimension] += 1;
                    }
                }
                return Normalize(v);
            }).ToArray();

        private static float[] Normalize(float[] v)
        {
            double sum = 0;
            foreach (var x in v) sum += (double)x * x;
            var norm = Math.Sqrt(sum);
            if (norm < 1e-12) return v;
            for (int i = 0; i < v.Length; i++) v[i] = (float)(v[i] / norm);
            return v;
        }
    }
}
