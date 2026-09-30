using System.Globalization;

namespace DraftZero.Core;

/// <summary>字面信号（第一层：中英文词、汉字短片段、标题）。对齐 Mac LiteralSignals.swift。</summary>
public static class LiteralSignals
{
    /// <summary>拉丁词（小写，≥2 字符）+ 汉字二元组。</summary>
    public static HashSet<string> Tokens(string text)
    {
        var lowered = text.ToLowerInvariant();
        var result = new HashSet<string>();

        // [a-z0-9]{2,}
        int runStart = -1;
        for (int i = 0; i <= lowered.Length; i++)
        {
            bool isToken = i < lowered.Length && IsLatinTokenChar(lowered[i]);
            if (isToken)
            {
                if (runStart < 0) runStart = i;
            }
            else if (runStart >= 0)
            {
                if (i - runStart >= 2) result.Add(lowered.Substring(runStart, i - runStart));
                runStart = -1;
            }
        }

        // CJK 相邻二元组（Unicode scalar 层；BMP 内即 char 层，代理对不可能是 CJK 基本区）。
        var scalars = new List<int>(lowered.Length);
        foreach (var rune in lowered.EnumerateRunes()) scalars.Add(rune.Value);
        for (int i = 0; i + 1 < scalars.Count; i++)
        {
            if (IsCjk(scalars[i]) && IsCjk(scalars[i + 1]))
            {
                result.Add(char.ConvertFromUtf32(scalars[i]) + char.ConvertFromUtf32(scalars[i + 1]));
            }
        }
        return result;
    }

    private static bool IsLatinTokenChar(char c) =>
        (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');

    private static bool IsCjk(int scalar) =>
        (scalar >= 0x4E00 && scalar <= 0x9FFF) || (scalar >= 0x3400 && scalar <= 0x4DBF);

    public static double Jaccard(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count == 0 || b.Count == 0) return 0;
        int inter = 0;
        foreach (var t in a)
        {
            if (b.Contains(t)) inter++;
        }
        return (double)inter / (a.Count + b.Count - inter);
    }

    /// <summary>共同术语按"更长更罕见"优先，用于证据展示；并列按字典序。</summary>
    public static List<string> CommonTerms(HashSet<string> a, HashSet<string> b, int limit = 6)
    {
        var shared = new List<string>();
        foreach (var t in a)
        {
            if (b.Contains(t)) shared.Add(t);
        }
        shared.Sort((lhs, rhs) =>
        {
            if (lhs.Length != rhs.Length) return rhs.Length - lhs.Length;
            return string.CompareOrdinal(lhs, rhs);
        });
        return shared.Take(limit).ToList();
    }
}
