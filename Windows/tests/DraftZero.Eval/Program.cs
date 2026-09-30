using System.Security.Cryptography;
using System.Text.Json;
using DraftZero.Core;

/// <summary>
/// DraftZero.Eval —— Windows C# 引擎的质量关口评估器（M0，对齐 Mac dz-eval 口径）。
///
/// 子命令：
///   golden --model M.onnx --tokenizer T.json --golden G.json [--out R.json]
///       逐条校验：C# token IDs == Mac CoreML 黄金 token IDs（完全一致）；
///       C# ONNX 向量 vs Mac CoreML 黄金向量余弦 ≥ 0.995。
///   eval --testset DIR --gt GT.json --db DB.sqlite --model M.onnx --tokenizer T.json --out R.json
///       冻结 30 份集：生产导入器 → CandidateEngine → 评估 recall@5 与 prec@3
///       （口径与 Mac dz-eval 完全同构：pending 全部 kind，score 降序 + 对端 UUID 升序）。
/// </summary>

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("用法: eval golden ... | eval eval ...");
            return 2;
        }
        try
        {
            return args[0] switch
            {
                "golden" => await RunGoldenAsync(args).ConfigureAwait(false),
                "eval" => await RunEvalAsync(args).ConfigureAwait(false),
                _ => 2,
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"FATAL: {ex}");
            return 1;
        }
    }

    private static string? Arg(string[] args, string flag) =>
        args.Length > Array.IndexOf(args, flag) + 1 ? args[Array.IndexOf(args, flag) + 1] : null;

    private sealed record GoldenItem(string Id, string Text, long[] TokenIds, float[] Vector);

    // ---- M0 第一关：token IDs 与黄金向量 ----

    private static async Task<int> RunGoldenAsync(string[] args)
    {
        var model = Arg(args, "--model") ?? throw new ArgumentException("缺少 --model");
        var tokenizerPath = Arg(args, "--tokenizer") ?? throw new ArgumentException("缺少 --tokenizer");
        var goldenPath = Arg(args, "--golden") ?? throw new ArgumentException("缺少 --golden");
        var outPath = Arg(args, "--out");

        var golden = JsonSerializer.Deserialize<List<GoldenItem>>(await File.ReadAllTextAsync(goldenPath).ConfigureAwait(false),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("黄金样本无法解析");

        using var embedder = new E5OnnxEmbedder(model, tokenizerPath);
        int tokenMismatches = 0;
        double minCosine = double.MaxValue;
        var perItem = new List<object>();
        foreach (var item in golden)
        {
            var ids = embedder.TokenizeForTest(E5OnnxEmbedder.QueryPrefix + item.Text);
            bool tokensEqual = ids.Length == item.TokenIds.Length
                && ids.Zip(item.TokenIds).All(p => p.First == p.Second);
            if (!tokensEqual) tokenMismatches++;
            var vector = embedder.Embed([item.Text])[0];
            var cosine = Cosine(vector, item.Vector);
            minCosine = Math.Min(minCosine, cosine);
            perItem.Add(new
            {
                id = item.Id,
                tokenCountCSharp = ids.Length,
                tokenCountGolden = item.TokenIds.Length,
                tokensEqual,
                cosine = Math.Round(cosine, 6),
            });
            Console.WriteLine($"{item.Id}: tokens={(tokensEqual ? "OK" : "MISMATCH")} cosine={cosine:0.000000}");
        }

        Console.WriteLine($"token mismatches = {tokenMismatches}/{golden.Count}");
        Console.WriteLine($"min cosine       = {minCosine:0.000000}（门槛 0.995）");
        var pass = tokenMismatches == 0 && minCosine >= 0.995;
        Console.WriteLine(pass ? "M0 GOLDEN: PASS" : "M0 GOLDEN: FAIL");
        if (outPath is not null)
        {
            await File.WriteAllTextAsync(outPath, JsonSerializer.Serialize(new
            {
                tokenMismatches,
                total = golden.Count,
                minCosine,
                threshold = 0.995,
                pass,
                perItem,
            }, new JsonSerializerOptions { WriteIndented = true })).ConfigureAwait(false);
        }
        return pass ? 0 : 1;
    }

    // ---- M0 第二关：冻结 30 份集 ----

    private sealed record GroundTruthFile(
        Dictionary<string, List<string>> Threads,
        List<List<string>> Duplicates,
        List<string>? Unrelated);

    private static async Task<int> RunEvalAsync(string[] args)
    {
        var testset = Arg(args, "--testset") ?? throw new ArgumentException("缺少 --testset");
        var gtPath = Arg(args, "--gt") ?? throw new ArgumentException("缺少 --gt");
        var dbPath = Arg(args, "--db") ?? throw new ArgumentException("缺少 --db");
        var model = Arg(args, "--model") ?? throw new ArgumentException("缺少 --model");
        var tokenizerPath = Arg(args, "--tokenizer") ?? throw new ArgumentException("缺少 --tokenizer");
        var outPath = Arg(args, "--out") ?? "eval-report.json";

        // 1. 冻结素材校验（SHA-256 摘要进报告）。
        var fileUrls = Directory.GetFiles(testset)
            .Where(p => !Path.GetFileName(p).StartsWith('.'))
            .OrderBy(p => Path.GetFileName(p), StringComparer.Ordinal)
            .ToArray();
        var fileHashes = new Dictionary<string, string>();
        foreach (var path in fileUrls)
        {
            fileHashes[Path.GetFileName(path)] =
                Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(path).ConfigureAwait(false))).ToLowerInvariant();
        }

        // 2. 全新隔离库。
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(dbPath))!);
        foreach (var suffix in new[] { "", "-wal", "-shm" })
        {
            if (File.Exists(dbPath + suffix)) File.Delete(dbPath + suffix);
        }
        var snapshots = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(dbPath))!, "snapshots");
        Directory.CreateDirectory(snapshots);
        await using var database = new AppDatabase(dbPath, snapshots);

        // 3. 生产导入器逐份导入（文件名排序；重复指纹按生产规则拒绝）。
        var importer = new LocalFileImporter(database, snapshots);
        var drafts = new List<Draft>();
        var nameByDraft = new Dictionary<Guid, string>();
        int duplicateCount = 0;
        var failures = new List<string>();
        foreach (var path in fileUrls)
        {
            switch (await importer.ImportFileAsync(path).ConfigureAwait(false))
            {
                case ImportOutcome.Success s:
                    drafts.Add(s.Draft);
                    nameByDraft[s.Draft.Id] = Path.GetFileName(path);
                    break;
                case ImportOutcome.Duplicate:
                    duplicateCount++;
                    break;
                case ImportOutcome.Failure f:
                    failures.Add($"{Path.GetFileName(path)}: {f.Reason}");
                    break;
            }
        }

        // 4. 生产引擎：切片 → 索引 → 候选落库。
        using var embedder = new E5OnnxEmbedder(model, tokenizerPath);
        var engine = new CandidateEngine(database, embedder);
        var engineReport = await engine.RefreshAsync(drafts).ConfigureAwait(false);

        // 5. 评估（口径同 dz-eval）。
        var gt = JsonSerializer.Deserialize<GroundTruthFile>(
            await File.ReadAllTextAsync(gtPath).ConfigureAwait(false),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("标注无法解析");

        var threadOf = new Dictionary<string, string>();
        foreach (var (group, members) in gt.Threads)
        {
            foreach (var m in members) threadOf[m] = group;
        }
        var partners = new Dictionary<string, HashSet<string>>();
        foreach (var (name, group) in threadOf)
        {
            partners[name] = gt.Threads[group].ToHashSet();
            partners[name].Remove(name);
        }
        foreach (var pair in gt.Duplicates)
        {
            (partners.TryGetValue(pair[0], out var a) ? a : partners[pair[0]] = []).Add(pair[1]);
            (partners.TryGetValue(pair[1], out var b) ? b : partners[pair[1]] = []).Add(pair[0]);
        }

        static string Lang(string? text) =>
            text is not null && text.Any(c => c is >= '\u4E00' and <= '\u9FFF') ? "zh" : "en";

        var allPairs = await engine.AllPendingPairsAsync().ConfigureAwait(false);
        var chunkCount = await SemanticIndexStore.IndexChunkCountAsync(database).ConfigureAwait(false);

        var byDraft = new Dictionary<Guid, List<CandidatePair>>();
        foreach (var pair in allPairs)
        {
            (byDraft.TryGetValue(pair.DraftA, out var la) ? la : byDraft[pair.DraftA] = []).Add(pair);
            if (pair.DraftB != pair.DraftA)
            {
                (byDraft.TryGetValue(pair.DraftB, out var lb) ? lb : byDraft[pair.DraftB] = []).Add(pair);
            }
        }
        foreach (var key in byDraft.Keys)
        {
            byDraft[key].Sort((x, y) =>
            {
                int c = y.Score.CompareTo(x.Score);
                if (c != 0) return c;
                return string.CompareOrdinal(
                    Db.Uid(OtherOf(x, key)), Db.Uid(OtherOf(y, key)));
            });
        }

        int recallHits = 0, eligible = 0, precNum = 0, precDen = 0;
        var misses = new List<object>();
        var draftsOut = new List<object>();
        foreach (var draft in drafts)
        {
            var name = nameByDraft.GetValueOrDefault(draft.Id, draft.Title);
            if (!threadOf.TryGetValue(name, out var thread)) continue;
            eligible++;
            var plist = partners.GetValueOrDefault(name) ?? new HashSet<string>();
            var candidates = byDraft.GetValueOrDefault(draft.Id) ?? [];
            var entries = candidates.Select((pair, rank) => new
            {
                rank = rank + 1,
                other = nameByDraft.GetValueOrDefault(OtherOf(pair, draft.Id), "?"),
                kind = pair.Kind.DbValue(),
                score = Math.Round(pair.Score, 6),
                isPartner = plist.Contains(nameByDraft.GetValueOrDefault(OtherOf(pair, draft.Id), "?")),
            }).ToList();
            var hit = entries.Take(5).Any(e => e.isPartner);
            if (hit) recallHits++;
            var top3 = entries.Take(3).ToList();
            precNum += top3.Count(e => e.isPartner);
            precDen += top3.Count;
            var out1 = new
            {
                name, thread,
                partners = plist.OrderBy(n => n, StringComparer.Ordinal).ToList(),
                recallHitAt5 = hit,
                missPartners = hit ? new List<string>() : plist.OrderBy(n => n, StringComparer.Ordinal).ToList(),
                precTop3Correct = top3.Count(e => e.isPartner),
                precTop3Shown = top3.Count,
                candidates = entries,
            };
            draftsOut.Add(out1);
            if (!hit) misses.Add(out1);
        }

        double recallPct = eligible == 0 ? 0 : (double)recallHits / eligible * 100;
        double precPct = precDen == 0 ? 0 : (double)precNum / precDen * 100;
        bool pass = recallPct >= 80.0 && precPct >= 70.0;

        Console.WriteLine($"imported={drafts.Count} duplicate={duplicateCount} failures={failures.Count}");
        Console.WriteLine($"queue chunks={chunkCount} leads={engineReport.PendingLeads} dups={engineReport.PendingDuplicates}");
        Console.WriteLine($"recall@5 = {recallPct:0.0}% ({recallHits}/{eligible})");
        Console.WriteLine($"prec@3   = {precPct:0.0}% ({precNum}/{precDen})");
        Console.WriteLine(pass ? "M0 EVAL: PASS（双指标达标；正式集仍未验）" : "M0 EVAL: FAIL");

        var report = new
        {
            generatedAt = DateTime.UtcNow.ToString("o"),
            testset,
            fileSha256 = fileHashes,
            importedDocs = drafts.Count,
            importStats = new { success = drafts.Count, duplicate = duplicateCount, failure = failures },
            queue = new { chunks = chunkCount, engineReport.PendingLeads, engineReport.PendingDuplicates },
            recall = new { hits = recallHits, eligible, percent = Math.Round(recallPct, 2), threshold = 80 },
            precision = new { numerator = precNum, denominator = precDen, percent = Math.Round(precPct, 2), threshold = 70 },
            pass,
            misses,
            drafts = draftsOut,
        };
        await File.WriteAllTextAsync(outPath, JsonSerializer.Serialize(report,
            new JsonSerializerOptions { WriteIndented = true })).ConfigureAwait(false);
        Console.WriteLine($"report → {outPath}");
        return pass ? 0 : 1;
    }

    private static Guid OtherOf(CandidatePair pair, Guid id) =>
        pair.DraftA == id ? pair.DraftB : pair.DraftA;

    private static double Cosine(float[] a, float[] b)
    {
        double dot = 0, na = 0, nb = 0;
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++)
        {
            dot += (double)a[i] * b[i];
            na += (double)a[i] * a[i];
            nb += (double)b[i] * b[i];
        }
        return dot / Math.Max(Math.Sqrt(na) * Math.Sqrt(nb), 1e-12);
    }
}
