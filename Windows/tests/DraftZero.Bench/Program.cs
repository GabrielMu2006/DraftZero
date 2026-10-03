using System.Diagnostics;
using System.Text.Json;
using DraftZero.Core;
using GRDBLike = DraftZero.Core;

/// <summary>
/// DraftZero.Bench —— C# 引擎性能基准（2026-10-03）。只调用生产 API，不改引擎。
/// 与 Mac dz-bench 同口径：embed 微基准 + scale 规模曲线；语料为合成集（见证据文档）。
///
/// 用法：
///   bench embed   --model M.onnx --tokenizer T.json
///   bench scale   --corpus DIR --sizes 30,100,300,1000 --db DIR --model M --tokenizer T [--out JSON]
/// </summary>

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        try
        {
            return args.FirstOrDefault() switch
            {
                "embed" => RunEmbed(args),
                "scale" => await RunScaleAsync(args).ConfigureAwait(false),
                _ => Usage(),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"FATAL: {ex}");
            return 1;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("用法: bench embed --model M.onnx --tokenizer T.json | bench scale --corpus DIR --sizes N,N --db DIR --model M --tokenizer T [--out JSON]");
        return 2;
    }

    private static string? Arg(string[] args, string flag) =>
        args.Length > Array.IndexOf(args, flag) + 1 ? args[Array.IndexOf(args, flag) + 1] : null;

    private static (string Name, Func<int, string> Make)[] Buckets => new[]
    {
        ("zh-short-50", (Func<int, string>)(i => $"深夜灵感第{i}条：雨夜书店的桥段还可以再压一压，明天改。")),
        ("zh-medium-200", i => string.Concat(Enumerable.Repeat("本地优先的草稿收纳应用要把语义线索控制在可审的量级，", 3)) + $"编号{i}。"),
        ("zh-long-600", i => string.Concat(Enumerable.Repeat("这是一段足够长的中文段落，用来测试接近切片上限时分词与推理的开销。", 16)) + $"编号{i}。"),
        ("en-short-40", i => $"Bench note {i}: short English draft about benchmarking ideas."),
        ("en-long-600", i => string.Concat(Enumerable.Repeat("This paragraph is deliberately long to probe the chunking ceiling and inference cost. ", 6)) + $"id {i}."),
    };

    private static (double mean, double p50, double p95) Stats(List<double> xs)
    {
        var s = xs.OrderBy(x => x).ToList();
        return (s.Average(), s[s.Count / 2], s[(int)(s.Count * 0.95) / 1]);
    }

    private static int RunEmbed(string[] args)
    {
        var model = Arg(args, "--model") ?? throw new ArgumentException("缺少 --model");
        var tokenizer = Arg(args, "--tokenizer") ?? throw new ArgumentException("缺少 --tokenizer");
        using var embedder = new E5OnnxEmbedder(model, tokenizer);
        const int repeats = 30;
        Console.WriteLine($"engine=ONNX {(Path.GetFileName(model))} dim={embedder.Dimension} threads={Environment.ProcessorCount}");
        foreach (var (name, make) in Buckets)
        {
            var texts = Enumerable.Range(0, repeats).Select(make).ToArray();
            _ = embedder.Embed(new[] { texts[0] }); // 预热
            var samples = new List<double>();
            foreach (var t in texts)
            {
                var sw = Stopwatch.StartNew();
                _ = embedder.Embed(new[] { t });
                sw.Stop();
                samples.Add(sw.Elapsed.TotalMilliseconds);
            }
            var (mean, p50, p95) = Stats(samples);
            Console.WriteLine($"{name,-14} mean {mean,7:F2} ms  p50 {p50,7:F2}  p95 {p95,7:F2}  (n={repeats})");
        }
        var mixed = Enumerable.Range(0, 300).Select(i => Buckets[i % Buckets.Length].Make(i)).ToArray();
        _ = embedder.Embed(new[] { mixed[0] });
        var swBulk = Stopwatch.StartNew();
        _ = embedder.Embed(mixed);
        swBulk.Stop();
        Console.WriteLine($"bulk 300 chunks: {swBulk.Elapsed.TotalMilliseconds:F0} ms → {300.0 / swBulk.Elapsed.TotalSeconds:F1} chunks/s（生产逐条路径）");
        return 0;
    }

    private sealed record ScaleRow(int Docs, int Chunks, double IndexMs, double IndexMsPerChunk,
        double RegenerateMs, double Regenerate2Ms, int PendingLeads, int PendingDuplicates, double TotalMs);

    private static async Task<int> RunScaleAsync(string[] args)
    {
        var corpus = Arg(args, "--corpus") ?? throw new ArgumentException("缺少 --corpus");
        var dbRoot = Arg(args, "--db") ?? throw new ArgumentException("缺少 --db");
        var model = Arg(args, "--model") ?? throw new ArgumentException("缺少 --model");
        var tokenizer = Arg(args, "--tokenizer") ?? throw new ArgumentException("缺少 --tokenizer");
        var outPath = Arg(args, "--out");
        var sizes = (Arg(args, "--sizes") ?? "30,100,300,1000")
            .Split(',', StringSplitOptions.RemoveEmptyEntries).Select(int.Parse).ToArray();

        Directory.CreateDirectory(dbRoot);
        var rows = new List<ScaleRow>();
        foreach (var size in sizes)
        {
            var dir = Path.Combine(corpus, $"corpus-{size}");
            var files = Directory.EnumerateFiles(dir)
                .Where(f => !Path.GetFileName(f).StartsWith('.'))
                .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal)
                .Take(size).ToList();
            var drafts = new List<Draft>();
            foreach (var f in files)
            {
                drafts.Add(new Draft
                {
                    Title = Path.GetFileName(f),
                    Content = await File.ReadAllTextAsync(f).ConfigureAwait(false),
                    SourceType = SourceType.LocalFile,
                    SourceLocation = f,
                    SourceLabel = Path.GetFileName(f),
                });
            }
            var dbPath = Path.Combine(dbRoot, $"bench-{size}.sqlite");
            foreach (var s in new[] { "", "-wal", "-shm" }) File.Delete(dbPath + s);

            await using var database = new AppDatabase(dbPath);
            // 生产流程先落库再索引（indexChunk 外键指向 draft）；本基准只计引擎段，不含入库
            foreach (var d in drafts)
            {
                await database.InsertDraftAsync(d, initialVersion: false).ConfigureAwait(false);
            }
            using var embedder = new E5OnnxEmbedder(model, tokenizer);
            var engine = new CandidateEngine(database, embedder);

            var sw = Stopwatch.StartNew();
            await SemanticIndexStore.RefreshSemanticIndexAsync(database, drafts, embedder).ConfigureAwait(false);
            sw.Stop();
            var indexMs = sw.Elapsed.TotalMilliseconds;

            sw = Stopwatch.StartNew();
            await engine.RegenerateAsync(drafts).ConfigureAwait(false);
            sw.Stop();
            var regenMs = sw.Elapsed.TotalMilliseconds;

            sw = Stopwatch.StartNew();
            await engine.RegenerateAsync(drafts).ConfigureAwait(false);
            sw.Stop();
            var regen2Ms = sw.Elapsed.TotalMilliseconds;

            var chunks = await SemanticIndexStore.IndexChunkCountAsync(database).ConfigureAwait(false);
            var report = await engine.CountsAsync().ConfigureAwait(false);
            rows.Add(new ScaleRow(size, chunks, indexMs, indexMs / Math.Max(chunks, 1),
                regenMs, regen2Ms, report.PendingLeads, report.PendingDuplicates, indexMs + regenMs));
            Console.WriteLine($"n={size,4} chunks={chunks,5}  index {indexMs,7:F0} ms ({indexMs / Math.Max(chunks, 1),4:F1} ms/chunk)  regen {regenMs,7:F0} ms (2nd {regen2Ms,7:F0})  leads={report.PendingLeads} dups={report.PendingDuplicates}");
        }
        if (outPath is not null)
        {
            await File.WriteAllTextAsync(outPath, JsonSerializer.Serialize(rows,
                new JsonSerializerOptions { WriteIndented = true })).ConfigureAwait(false);
            Console.WriteLine($"report → {outPath}");
        }
        return 0;
    }
}
