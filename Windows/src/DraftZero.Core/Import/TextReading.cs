using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;

namespace DraftZero.Core;

/// <summary>导入相关的纯文本处理：编码读取、标题提取、归一化指纹。对齐 Mac TextReading.swift。</summary>
public static class TextReading
{
    /// <summary>TXT/Markdown 读取：优先 UTF-8，失败回退 GB18030（中文用户常见旧文件）。</summary>
    public static string ReadText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // 严格 UTF-8：有 BOM 或无 BOM 都按 UTF-8 校验（throwOnInvalid）。
        try
        {
            var strict = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
            return strict.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
        }
        try
        {
            var gb18030 = Encoding.GetEncoding("GB18030");
            return gb18030.GetString(bytes);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException("无法识别文件编码（尝试过 UTF-8 与 GB18030）", ex);
        }
    }

    /// <summary>标题：Markdown 一级标题优先，否则第一行非空文字，截到 80 字。</summary>
    public static string ExtractTitle(string text, string fallback)
    {
        foreach (var rawLine in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim(' ', '\t', '　');
            if (line.StartsWith('#'))
            {
                var heading = line.TrimStart('#').Trim(' ', '\t', '　');
                if (heading.Length > 0) return Truncate(heading, 80);
            }
            if (line.Length > 0) return Truncate(line, 80);
        }
        return string.IsNullOrWhiteSpace(fallback) ? "未命名草稿" : fallback;
    }

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s.Substring(0, max);

    /// <summary>归一化正文指纹：过滤 Unicode 字母/数字/标记标量 → 小写 → SHA-256 hex。
    /// 与 Mac CharacterSet.alphanumerics（Letters+Marks+Numbers）对齐。</summary>
    public static string Fingerprint(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.IsLetter(rune) || Rune.IsNumber(rune) || System.Globalization.UnicodeCategory.NonSpacingMark == Rune.GetUnicodeCategory(rune) || System.Globalization.UnicodeCategory.SpacingCombiningMark == Rune.GetUnicodeCategory(rune) || System.Globalization.UnicodeCategory.EnclosingMark == Rune.GetUnicodeCategory(rune))
            {
                sb.Append(rune.ToString());
            }
        }
        var normalized = sb.ToString().ToLowerInvariant();
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }
}
