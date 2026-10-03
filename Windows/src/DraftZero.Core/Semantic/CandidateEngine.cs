using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

public enum CandidateKind
{
    Lead,       // 项目线索
    Duplicate,  // 可能重复
}

public enum CandidateStatus
{
    Pending,
    Accepted,
    Rejected,
    Deferred,
}

public static class CandidateKindExtensions
{
    public static string DbValue(this CandidateKind k) => k == CandidateKind.Lead ? "lead" : "duplicate";
    public static CandidateKind FromDb(string v) => v == "lead" ? CandidateKind.Lead : CandidateKind.Duplicate;
}

public static class CandidateStatusExtensions
{
    public static string DbValue(this CandidateStatus s) => s switch
    {
        CandidateStatus.Pending => "pending",
        CandidateStatus.Accepted => "accepted",
        CandidateStatus.Rejected => "rejected",
        CandidateStatus.Deferred => "deferred",
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };
    public static CandidateStatus FromDb(string v) => v switch
    {
        "pending" => CandidateStatus.Pending,
        "accepted" => CandidateStatus.Accepted,
        "rejected" => CandidateStatus.Rejected,
        "deferred" => CandidateStatus.Deferred,
        _ => throw new FormatException($"未知候选状态：{v}"),
    };
}

/// <summary>可定位的证据（R-004"给出证据"）。JSON 序列化字段名与 Mac PairEvidence 一致。</summary>
public record PairEvidence
{
    public record Snippet
    {
        [JsonPropertyName("draftId")] public Guid DraftId { get; init; }
        [JsonPropertyName("chunkIndex")] public int ChunkIndex { get; init; }
        [JsonPropertyName("startOffset")] public int StartOffset { get; init; }
        [JsonPropertyName("heading")] public string? Heading { get; init; }
        [JsonPropertyName("text")] public string Text { get; init; } = "";
    }

    [JsonPropertyName("a")] public Snippet A { get; init; } = new();
    [JsonPropertyName("b")] public Snippet B { get; init; } = new();
    /// <summary>共同术语；为空表示纯语义相近，界面显示"内容含义相近"。</summary>
    [JsonPropertyName("commonTerms")] public List<string> CommonTerms { get; init; } = [];
    [JsonPropertyName("semanticScore")] public double SemanticScore { get; init; }
    [JsonPropertyName("literalScore")] public double LiteralScore { get; init; }
}

/// <summary>候选对。接受/拒绝/暂缓由用户决定；候选不是项目归属（SPEC §5）。</summary>
public record CandidatePair
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public Guid DraftA { get; init; }
    public Guid DraftB { get; init; }
    public CandidateKind Kind { get; set; }
    public double Score { get; set; }
    public string? Evidence { get; set; }
    public CandidateStatus Status { get; set; } = CandidateStatus.Pending;
    public string? FingerprintA { get; set; }
    public string? FingerprintB { get; set; }
    /// <summary>重新分析后保留此前裁决记录供辨认（R-004 表格第 4 行）。</summary>
    public string? LastDecision { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? DecidedAt { get; set; }

    public PairEvidence? EvidenceDecoded()
    {
        if (Evidence is null) return null;
        try
        {
            return JsonSerializer.Deserialize<PairEvidence>(Evidence);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public bool Involves(Guid draftId) => DraftA == draftId || DraftB == draftId;

    public Guid? Other(Guid draftId) =>
        DraftA == draftId ? DraftB : DraftB == draftId ? DraftA : null;
}

/// <summary>候选引擎冻结参数（A-007；取值依据见 Mac CandidateTuning 与消融报告）。</summary>
public static class CandidateTuning
{
    /// <summary>语义近重复阈值（spike：重复文件对 1.000，无关对均值 ~0.80）。</summary>
    public const double DuplicateSemantic = 0.98;
    /// <summary>项目线索地板只负责拦住完全无关的长尾（语义 &lt;0.45）。</summary>
    public const double LeadSemanticFloor = 0.90;
    /// <summary>合成分地板：排序已不含字面分量（literalWeight = 0）。</summary>
    public const double LeadCombined = 0.90;
    public const double SemanticWeight = 1.0;
    public const double LiteralWeight = 0.0;
    /// <summary>每份草稿保留的候选数（质量关口按"前 5"评估，多留一个余量）。</summary>
    public const int TopKPerDraft = 6;
    /// <summary>
    /// 产生"项目线索"（语义）候选的最低正文字符数（F-008 实测：短文在 e5-small 下
    /// 基线相似度高，一句话/名单类草稿会与任何内容形成噪声线索）。
    /// "可能重复"（指纹判定）不受此限制——两份相同短稿仍应提示。
    /// </summary>
    public const int MinLeadCharacters = 30;
}

public record CandidateReport(int IndexedDrafts, int PendingLeads, int PendingDuplicates);

/// <summary>候选引擎（对齐 Mac CandidateEngine.swift，含增量索引、每稿 topK 并集、拒绝抑制）。</summary>
public sealed class CandidateEngine
{
    private readonly AppDatabase _database;
    public ITextEmbedding Embedder { get; }

    public CandidateEngine(AppDatabase database, ITextEmbedding embedder)
    {
        _database = database;
        Embedder = embedder;
    }

    /// <summary>增量索引 + 重新生成候选（新增/编辑/删除只影响相关内容）。</summary>
    public async Task<CandidateReport> RefreshAsync(IReadOnlyList<Draft> drafts)
    {
        await SemanticIndexStore.RefreshSemanticIndexAsync(_database, drafts, Embedder).ConfigureAwait(false);
        await RegenerateAsync(drafts).ConfigureAwait(false);
        return await CountsAsync().ConfigureAwait(false);
    }

    // MARK: 候选生成

    private sealed record ScoredPair(Guid A, Guid B, double Semantic, double Combined, double Literal,
        bool IsDuplicate, PairEvidence Evidence);

    public async Task RegenerateAsync(IReadOnlyList<Draft> drafts)
    {
        var chunksByDraft = await SemanticIndexStore.ChunksByDraftAsync(_database).ConfigureAwait(false);
        var fingerprints = drafts.ToDictionary(d => d.Id, d => TextReading.Fingerprint(d.Content ?? ""));
        var bodyTokens = drafts.ToDictionary(d => d.Id, d => LiteralSignals.Tokens(d.Content ?? ""));
        var titleTokens = drafts.ToDictionary(d => d.Id, d => LiteralSignals.Tokens(d.Title));

        var withVectors = drafts.Where(d => chunksByDraft.TryGetValue(d.Id, out var c) && c.Count > 0).ToList();
        var candidates = new Dictionary<string, ScoredPair>();

        for (int i = 0; i < withVectors.Count; i++)
        {
            for (int j = i + 1; j < withVectors.Count; j++)
            {
                var draftA = withVectors[i];
                var draftB = withVectors[j];
                var chunksA = chunksByDraft[draftA.Id];
                var chunksB = chunksByDraft[draftB.Id];

                // 文档分 = 切片对最大余弦，并保留最佳切片对作证据（"相近段落"）。
                double best = double.NegativeInfinity;
                SemanticIndexStore.IndexChunkRow? bestA = null, bestB = null;
                foreach (var chunkA in chunksA)
                {
                    foreach (var chunkB in chunksB)
                    {
                        double s = Cosine(chunkA.Vector, chunkB.Vector);
                        if (s > best)
                        {
                            best = s;
                            bestA = chunkA;
                            bestB = chunkB;
                        }
                    }
                }
                if (best <= 0 || bestA is null || bestB is null) continue;

                double literal = LiteralScore(
                    bodyTokens[draftA.Id], bodyTokens[draftB.Id],
                    titleTokens[draftA.Id], titleTokens[draftB.Id]);
                double combined = CandidateTuning.SemanticWeight * best
                    + CandidateTuning.LiteralWeight * literal;
                bool isDuplicate = best >= CandidateTuning.DuplicateSemantic
                    || fingerprints[draftA.Id] == fingerprints[draftB.Id];
                // F-008：线索候选要求双方正文达到最低长度；重复候选不受限
                bool bothLeadEligible =
                    (draftA.Content?.Trim().Length ?? 0) >= CandidateTuning.MinLeadCharacters
                    && (draftB.Content?.Trim().Length ?? 0) >= CandidateTuning.MinLeadCharacters;
                if (!isDuplicate && (!bothLeadEligible || !(best >= CandidateTuning.LeadSemanticFloor
                                      && combined >= CandidateTuning.LeadCombined)))
                {
                    continue;
                }

                var evidence = new PairEvidence
                {
                    A = new PairEvidence.Snippet
                    {
                        DraftId = draftA.Id, ChunkIndex = bestA.ChunkIndex,
                        StartOffset = bestA.StartOffset, Heading = bestA.Heading, Text = bestA.Text,
                    },
                    B = new PairEvidence.Snippet
                    {
                        DraftId = draftB.Id, ChunkIndex = bestB.ChunkIndex,
                        StartOffset = bestB.StartOffset, Heading = bestB.Heading, Text = bestB.Text,
                    },
                    CommonTerms = LiteralSignals.CommonTerms(bodyTokens[draftA.Id], bodyTokens[draftB.Id]),
                    SemanticScore = best,
                    LiteralScore = literal,
                };

                var pair = new ScoredPair(draftA.Id, draftB.Id, best, combined, literal, isDuplicate, evidence);
                var key = PairKey(draftA.Id, draftB.Id);
                if (candidates.TryGetValue(key, out var existing) && existing.Combined >= pair.Combined)
                {
                    continue;
                }
                candidates[key] = pair;
            }
        }

        // 每份草稿保留**自己的**前 K 个候选（并集）；旧实现是全局贪心双边截断，
        // 会造成查询不对称（Mac V0.1.0 已修复的历史缺陷，移植不得回退）。
        var perDraft = new Dictionary<Guid, List<ScoredPair>>();
        foreach (var pair in candidates.Values.Order(RankOrderComparer.Instance))
        {
            if (!perDraft.TryGetValue(pair.A, out var listA)) perDraft[pair.A] = listA = [];
            listA.Add(pair);
            if (pair.B != pair.A)
            {
                if (!perDraft.TryGetValue(pair.B, out var listB)) perDraft[pair.B] = listB = [];
                listB.Add(pair);
            }
        }
        var kept = new Dictionary<string, ScoredPair>();
        foreach (var list in perDraft.Values)
        {
            foreach (var pair in list.Take(CandidateTuning.TopKPerDraft))
            {
                kept[PairKey(pair.A, pair.B)] = pair;
            }
        }

        // 落库（R-004 表格）：pending 更新；rejected/deferred 内容未变则抑制；
        // 内容已变可产生新候选，旧记录保留；无正文文档不产生候选。
        await _database.WriteAsync(conn =>
        {
            using var tx = conn.BeginTransaction();
            foreach (var pair in kept.Values)
            {
                var rows = Db.ReadRows(conn, """
                    SELECT * FROM candidatePair
                    WHERE (draftA=@a AND draftB=@b) OR (draftA=@b AND draftB=@a)
                    ORDER BY createdAt DESC LIMIT 1
                    """,
                    Db.P("@a", Db.Uid(pair.A)), Db.P("@b", Db.Uid(pair.B)));
                var kind = pair.IsDuplicate ? CandidateKind.Duplicate : CandidateKind.Lead;
                var evidenceJson = JsonSerializer.Serialize(pair.Evidence);

                if (rows.Count == 0)
                {
                    Db.Exec(conn, """
                        INSERT INTO candidatePair (id,draftA,draftB,kind,score,evidence,status,fingerprintA,fingerprintB,lastDecision,createdAt,decidedAt)
                        VALUES (@id,@a,@b,@kind,@score,@evidence,'pending',@fpA,@fpB,NULL,@createdAt,NULL)
                        """,
                        Db.P("@id", Db.Uid(Guid.NewGuid())),
                        Db.P("@a", Db.Uid(pair.A)), Db.P("@b", Db.Uid(pair.B)),
                        Db.P("@kind", kind.DbValue()), Db.P("@score", pair.Combined),
                        Db.P("@evidence", evidenceJson),
                        Db.P("@fpA", fingerprints[pair.A]), Db.P("@fpB", fingerprints[pair.B]),
                        Db.P("@createdAt", Db.Fmt(DateTime.UtcNow)));
                    continue;
                }

                var row = rows[0];
                var status = CandidateStatusExtensions.FromDb(Db.Str(row, "status")!);
                if (status == CandidateStatus.Pending)
                {
                    Db.Exec(conn, """
                        UPDATE candidatePair SET score=@score, kind=@kind, evidence=@evidence WHERE id=@id
                        """,
                        Db.P("@score", pair.Combined), Db.P("@kind", kind.DbValue()),
                        Db.P("@evidence", evidenceJson), Db.P("@id", Db.Str(row, "id")));
                    continue;
                }

                var unchanged = Db.Str(row, "fingerprintA") == fingerprints[pair.A]
                    && Db.Str(row, "fingerprintB") == fingerprints[pair.B];
                if (!unchanged)
                {
                    var lastDecision = Db.Str(row, "lastDecision")
                        ?? $"{status.DbValue()}（内容已变化）";
                    Db.Exec(conn, """
                        INSERT INTO candidatePair (id,draftA,draftB,kind,score,evidence,status,fingerprintA,fingerprintB,lastDecision,createdAt,decidedAt)
                        VALUES (@id,@a,@b,@kind,@score,@evidence,'pending',@fpA,@fpB,@lastDecision,@createdAt,NULL)
                        """,
                        Db.P("@id", Db.Uid(Guid.NewGuid())),
                        Db.P("@a", Db.Uid(pair.A)), Db.P("@b", Db.Uid(pair.B)),
                        Db.P("@kind", kind.DbValue()), Db.P("@score", pair.Combined),
                        Db.P("@evidence", evidenceJson),
                        Db.P("@fpA", fingerprints[pair.A]), Db.P("@fpB", fingerprints[pair.B]),
                        Db.P("@lastDecision", lastDecision),
                        Db.P("@createdAt", Db.Fmt(DateTime.UtcNow)));
                }
            }
            tx.Commit();
            return Task.CompletedTask;
        }).ConfigureAwait(false);
    }

    private sealed class RankOrderComparer : IComparer<ScoredPair>
    {
        public static readonly RankOrderComparer Instance = new();
        public int Compare(ScoredPair? x, ScoredPair? y)
        {
            if (x is null || y is null) return 0;
            // combined 降序 → semantic 降序 → literal 降序 → pairKey 升序（固定可重复）。
            int c = y.Combined.CompareTo(x.Combined);
            if (c != 0) return c;
            c = y.Semantic.CompareTo(x.Semantic);
            if (c != 0) return c;
            c = y.Literal.CompareTo(x.Literal);
            if (c != 0) return c;
            return string.CompareOrdinal(PairKey(x.A, x.B), PairKey(y.A, y.B));
        }
    }

    public static string PairKey(Guid a, Guid b)
    {
        var sa = Db.Uid(a);
        var sb = Db.Uid(b);
        return string.CompareOrdinal(sa, sb) < 0 ? $"{sa}|{sb}" : $"{sb}|{sa}";
    }

    public static double LiteralScore(HashSet<string> bodyA, HashSet<string> bodyB,
        HashSet<string> titleA, HashSet<string> titleB) =>
        0.7 * LiteralSignals.Jaccard(bodyA, bodyB) + 0.3 * LiteralSignals.Jaccard(titleA, titleB);

    public static double Cosine(float[] a, float[] b)
    {
        double dot = 0, na = 0, nb = 0;
        int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            dot += (double)a[i] * b[i];
            na += (double)a[i] * a[i];
            nb += (double)b[i] * b[i];
        }
        return dot / Math.Max(Math.Sqrt(na) * Math.Sqrt(nb), 1e-12);
    }

    // MARK: 队列与裁决

    public async Task<CandidateReport> CountsAsync()
    {
        var (indexed, leads, dups) = await _database.WriteAsync(conn =>
        {
            long indexed = Db.Long(conn, "SELECT count(*) FROM indexStatus") ?? 0;
            long leads = Db.Long(conn, """
                SELECT count(*) FROM candidatePair WHERE status='pending' AND kind='lead'
                """) ?? 0;
            long dups = Db.Long(conn, """
                SELECT count(*) FROM candidatePair WHERE status='pending' AND kind='duplicate'
                """) ?? 0;
            return Task.FromResult(((int)indexed, (int)leads, (int)dups));
        }).ConfigureAwait(false);
        return new CandidateReport(indexed, leads, dups);
    }

    public async Task<List<CandidatePair>> QueueAsync(CandidateKind? kind = null, CandidateStatus status = CandidateStatus.Pending)
    {
        var sql = "SELECT * FROM candidatePair WHERE status=@status";
        var args = new List<SqliteParameter> { Db.P("@status", status.DbValue()) };
        if (kind is not null)
        {
            sql += " AND kind=@kind";
            args.Add(Db.P("@kind", kind.Value.DbValue()));
        }
        sql += " ORDER BY score DESC, draftA ASC, draftB ASC";
        return await _database.WriteAsync(conn =>
            Task.FromResult(Db.ReadRows(conn, sql, args.ToArray()).Select(ReadPair).ToList()))
            .ConfigureAwait(false);
    }

    public async Task<List<CandidatePair>> AllPendingPairsAsync() =>
        await QueueAsync(kind: null).ConfigureAwait(false);

    private static CandidatePair ReadPair(Dictionary<string, object?> r) => new()
    {
        Id = Db.Uid(Db.Str(r, "id")!),
        DraftA = Db.Uid(Db.Str(r, "draftA")!),
        DraftB = Db.Uid(Db.Str(r, "draftB")!),
        Kind = CandidateKindExtensions.FromDb(Db.Str(r, "kind")!),
        Score = Db.Dbl(r, "score"),
        Evidence = Db.Str(r, "evidence"),
        Status = CandidateStatusExtensions.FromDb(Db.Str(r, "status")!),
        FingerprintA = Db.Str(r, "fingerprintA"),
        FingerprintB = Db.Str(r, "fingerprintB"),
        LastDecision = Db.Str(r, "lastDecision"),
        CreatedAt = Db.ParseTime(Db.Str(r, "createdAt")) ?? DateTime.UtcNow,
        DecidedAt = Db.ParseTime(Db.Str(r, "decidedAt")),
    };

    /// <summary>
    /// 候选组预览（R-004"形成候选组"）：从待审线索对贪心聚合；每个成员都必须与组内
    /// 某成员有直接证据；桥接文档可出现在多个组；不做 A~B~C ⇒ A~C 的传递推断。
    /// </summary>
    public static List<List<CandidatePair>> CandidateGroups(IReadOnlyList<CandidatePair> pendingLeads)
    {
        var groups = new List<List<CandidatePair>>();
        // ForGroupsComparer 本身已实现"分数降序"语义（x 大在前），故用 Order 而非
        // OrderDescending（后者会再翻转一次比较器，退化为升序——已实测验证）。
        foreach (var pair in pendingLeads.Order(ForGroupsComparer.Instance))
        {
            int indexA = groups.FindIndex(members => members.Any(m => m.Involves(pair.DraftA)));
            int indexB = groups.FindIndex(members => members.Any(m => m.Involves(pair.DraftB)));
            switch (indexA, indexB)
            {
                case (-1, -1):
                    groups.Add([pair]);
                    break;
                case (int ia, -1):
                    groups[ia].Add(pair);
                    break;
                case (-1, int jb):
                    groups[jb].Add(pair);
                    break;
                case (int ia2, int jb2):
                    if (ia2 == jb2)
                    {
                        groups[ia2].Add(pair);
                    }
                    else
                    {
                        // 合并会造成无直接证据的成员 → 两组保持独立（桥接文档两边都出现）
                        groups[ia2].Add(pair);
                    }
                    break;
            }
        }
        return groups;
    }

    private sealed class ForGroupsComparer : IComparer<CandidatePair>
    {
        public static readonly ForGroupsComparer Instance = new();
        public int Compare(CandidatePair? x, CandidatePair? y)
        {
            if (x is null || y is null) return 0;
            int c = y.Score.CompareTo(x.Score);
            if (c != 0) return c;
            return string.CompareOrdinal(Db.Uid(x.Id), Db.Uid(y.Id));
        }
    }

    /// <summary>接受：把两端草稿加入项目（真实归属由 projectDraft 承担，幂等），候选标记已处理。</summary>
    public async Task AcceptAsync(Guid pairId, Guid addDraftsToProjectId) =>
        await _database.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM candidatePair WHERE id=@id", Db.P("@id", Db.Uid(pairId)));
            if (rows.Count == 0) return Task.CompletedTask;
            var pair = ReadPair(rows[0]);
            foreach (var draftId in new[] { pair.DraftA, pair.DraftB })
            {
                if (Db.Long(conn, "SELECT count(*) FROM draft WHERE id=@d", Db.P("@d", Db.Uid(draftId))) == 0) continue;
                if (Db.Long(conn, "SELECT count(*) FROM project WHERE id=@p", Db.P("@p", Db.Uid(addDraftsToProjectId))) == 0) continue;
                if (Db.Long(conn, "SELECT count(*) FROM projectDraft WHERE projectId=@p AND draftId=@d",
                    Db.P("@p", Db.Uid(addDraftsToProjectId)), Db.P("@d", Db.Uid(draftId))) > 0) continue;
                Db.Exec(conn, "INSERT INTO projectDraft (projectId,draftId) VALUES (@p,@d)",
                    Db.P("@p", Db.Uid(addDraftsToProjectId)), Db.P("@d", Db.Uid(draftId)));
            }
            Db.Exec(conn, "UPDATE candidatePair SET status='accepted', decidedAt=@t WHERE id=@id",
                Db.P("@t", Db.Fmt(DateTime.UtcNow)), Db.P("@id", Db.Uid(pairId)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    public async Task DecideAsync(Guid pairId, CandidateStatus status) =>
        await _database.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE candidatePair SET status=@s, decidedAt=@t WHERE id=@id",
                Db.P("@s", status.DbValue()), Db.P("@t", Db.Fmt(DateTime.UtcNow)), Db.P("@id", Db.Uid(pairId)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);

    /// <summary>用户主动重新分析：回到待审，保留此前裁决记录（R-004 表格第 4 行）。</summary>
    public async Task ReanalyzeAsync(Guid pairId) =>
        await _database.WriteAsync(conn =>
        {
            var rows = Db.ReadRows(conn, "SELECT * FROM candidatePair WHERE id=@id", Db.P("@id", Db.Uid(pairId)));
            if (rows.Count == 0) return Task.CompletedTask;
            var pair = ReadPair(rows[0]);
            string? lastDecision = pair.LastDecision;
            if (pair.Status != CandidateStatus.Pending)
            {
                var when = pair.DecidedAt?.ToString("o") ?? "";
                lastDecision = $"{pair.Status.DbValue()} {when}";
            }
            Db.Exec(conn, "UPDATE candidatePair SET status='pending', decidedAt=NULL, lastDecision=@ld WHERE id=@id",
                Db.P("@ld", lastDecision), Db.P("@id", Db.Uid(pairId)));
            return Task.CompletedTask;
        }).ConfigureAwait(false);
}
