namespace DraftZero.Core;

/// <summary>
/// 切片器（SPEC §3"切片与索引"）：按段落与标题切块，保留来源位置；超长段落硬切。
/// 对齐 Mac Chunker.swift（含"过短段落并入前一段"与句末标点硬切的全部规则）。
/// </summary>
public static class Chunker
{
    public record Chunk(int ChunkIndex, string Text, int StartOffset, string? Heading);

    internal const int MaxChunkCharacters = 600;
    internal const int MinChunkCharacters = 12;

    // Swift 原集合：{"。", ".", "！", "?", "；", ";"}（无全角问号，保持一致）。
    private static readonly char[] SentencePunctuation = { '。', '.', '！', '?', '；', ';' };

    public static List<Chunk> ChunkText(string text)
    {
        // 1. 按 "\n\n" 分段并定位原始偏移（与 Swift 相同的两步定位策略）。
        var paragraphs = new List<(string Text, int Offset)>();
        var rawParas = text.Split("\n\n", StringSplitOptions.None);
        int searchStart = 0;
        foreach (var rawPara in rawParas)
        {
            int idx = text.IndexOf(rawPara, searchStart, StringComparison.Ordinal);
            if (idx < 0) break;
            var trimmedText = rawPara.Trim(' ', '\t', '\r', '\n', '　');
            if (trimmedText.Length > 0)
            {
                int wsTrimmed = rawPara.Trim(' ', '\t', '　').Length;
                int offset = idx + (rawPara.Length - wsTrimmed) / 2;
                paragraphs.Add((trimmedText, Math.Max(0, offset)));
            }
            if (idx + rawPara.Length > searchStart)
            {
                searchStart = idx + rawPara.Length;
            }
        }

        // 2. 过短段落并入前一段，避免碎屑切片。
        var merged = new List<(string Text, int Offset)>();
        foreach (var para in paragraphs)
        {
            if (merged.Count > 0 &&
                (merged[^1].Text.Length < MinChunkCharacters || para.Text.Length < MinChunkCharacters))
            {
                var (lastText, lastOffset) = merged[^1];
                merged[^1] = (lastText + "\n\n" + para.Text, lastOffset);
            }
            else
            {
                merged.Add(para);
            }
        }

        // 3. 超长段落按句末标点硬切。
        var chunks = new List<Chunk>();
        foreach (var (paraText, offset) in merged)
        {
            var remaining = paraText;
            int pieceOffset = offset;
            while (remaining.Length > MaxChunkCharacters)
            {
                var head = remaining.Substring(0, MaxChunkCharacters);
                int cut = head.LastIndexOfAny(SentencePunctuation);
                if (cut < 0) cut = head.LastIndexOf('\n');
                // 防御性护栏：片段起点恰为标点时 lastIndex 可能落在 0，
                // 消费 0 字符会死循环；此时至少消费 1 字符（真实文本不会触发）。
                if (cut <= 0) cut = Math.Min(1, head.Length - 1);
                var piece = remaining.Substring(0, cut).Trim(' ', '\t', '\r', '\n', '　');
                if (piece.Length > 0)
                {
                    chunks.Add(MakeChunk(piece, pieceOffset));
                }
                pieceOffset += cut;
                remaining = remaining.Substring(cut);
            }
            var tail = remaining.Trim(' ', '\t', '\r', '\n', '　');
            if (tail.Length > 0)
            {
                chunks.Add(MakeChunk(tail, pieceOffset));
            }
        }

        return chunks.Select((c, i) => c with { ChunkIndex = i }).ToList();
    }

    private static Chunk MakeChunk(string piece, int offset)
    {
        // 块的"标题"取片段内的首个 Markdown 标题行（若有）。
        string? heading = null;
        foreach (var line in piece.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var t = line.Trim(' ', '\t');
            if (t.StartsWith('#'))
            {
                heading = t.TrimStart('#').Trim(' ', '\t');
                if (heading.Length > 60) heading = heading.Substring(0, 60);
                break;
            }
        }
        return new Chunk(0, piece, offset, heading);
    }
}
