using System.Text.Json;
using System.Text.Json.Serialization;

namespace DraftZero.Core;

/// <summary>单次导入结果（本地文件/网页/GitHub 通用）。</summary>
public abstract record ImportOutcome
{
    public record Success(Draft Draft) : ImportOutcome;
    /// <summary>已有相同来源或相同内容的快照（SPEC §6：先提示，允许取消或另存新快照）。</summary>
    public record Duplicate(Draft Existing) : ImportOutcome;
    public record Failure(string Reason) : ImportOutcome;

    public bool IsFailure => this is Failure;
}

/// <summary>批量导入中的一项：displayName 供结果面板展示，source 供"另存新快照"重试。</summary>
public record ImportedItem
{
    public abstract record ItemSource;
    public record LocalFileSource(string Path) : ItemSource;
    public record WebPageSource(string Url) : ItemSource;
    public record GitHubFileSource(GitHubImportRequest Request) : ItemSource;

    public required string DisplayName { get; init; }
    public ItemSource? Source { get; init; }
    public required ImportOutcome Outcome { get; init; }
}

/// <summary>仓库中待导入文件所需的全部信息（树接口已给出 SHA，导入时只需下载 raw 内容）。</summary>
public record GitHubImportRequest
{
    public required string Owner { get; init; }
    public required string Repo { get; init; }
    public required string Branch { get; init; }
    public required string TreeSha { get; init; }
    public required string Path { get; init; }
    public required string BlobSha { get; init; }

    [JsonIgnore]
    public string FileExtension => System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();

    [JsonIgnore]
    public string BlobUrl => $"https://github.com/{Owner}/{Repo}/blob/{Branch}/{Path}";
}

/// <summary>本地文件导入器（R-001）。逐项处理，单件失败不影响同批其他文件；
/// 原文件只读不写；文本副本存入工作区数据库。对齐 Mac LocalFileImporter.swift。</summary>
public sealed class LocalFileImporter
{
    public static readonly string[] SupportedExtensions = ["txt", "md", "markdown", "text", "pdf"];

    private readonly AppDatabase _database;
    private readonly string _snapshotsDirectory;

    public LocalFileImporter(AppDatabase database, string snapshotsDirectory)
    {
        _database = database;
        _snapshotsDirectory = snapshotsDirectory;
    }

    /// <summary>批量导入：逐项报告，一项失败不影响其他项（R-001 验收）。</summary>
    public async Task<List<ImportedItem>> ImportFilesAsync(IEnumerable<string> paths)
    {
        var results = new List<ImportedItem>();
        foreach (var path in paths)
        {
            results.Add(new ImportedItem
            {
                DisplayName = Path.GetFileName(path),
                Source = new ImportedItem.LocalFileSource(path),
                Outcome = await ImportFileAsync(path).ConfigureAwait(false),
            });
        }
        return results;
    }

    /// <summary>allowDuplicate：用户对重复提示选择"另存新快照"后置 true 重试。</summary>
    public async Task<ImportOutcome> ImportFileAsync(string path, bool allowDuplicate = false)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!SupportedExtensions.Contains(ext))
        {
            return new ImportOutcome.Failure($"不支持的文件类型：.{(ext.Length == 0 ? "（无扩展名）" : ext)}");
        }
        if (!File.Exists(path))
        {
            return new ImportOutcome.Failure($"文件不存在或无法访问：{Path.GetFileName(path)}");
        }
        return ext == "pdf"
            ? await ImportPdfAsync(path, allowDuplicate).ConfigureAwait(false)
            : await ImportTextFileAsync(path, allowDuplicate).ConfigureAwait(false);
    }

    private async Task<ImportOutcome> ImportTextFileAsync(string path, bool allowDuplicate)
    {
        string text;
        try
        {
            text = TextReading.ReadText(path);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure(ex.Message);
        }
        // 完全空白的文本不生成空草稿。
        if (string.IsNullOrWhiteSpace(text))
        {
            return new ImportOutcome.Failure("文件没有可读取的正文");
        }

        var fingerprint = TextReading.Fingerprint(text);
        if (!allowDuplicate)
        {
            var existing = await _database.FindExistingDraftAsync(path, fingerprint).ConfigureAwait(false);
            if (existing is not null) return new ImportOutcome.Duplicate(existing);
        }

        var draft = new Draft
        {
            Title = TextReading.ExtractTitle(text, Path.GetFileNameWithoutExtension(path)),
            Content = text,
            IsEditable = true,
            SourceType = SourceType.LocalFile,
            SourceLocation = path,
            SourceLabel = Path.GetFileName(path),
            Fingerprint = fingerprint,
        };
        try
        {
            await _database.InsertDraftAsync(draft, initialVersion: true).ConfigureAwait(false);
            return new ImportOutcome.Success(draft);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure($"保存失败：{ex.Message}");
        }
    }

    private async Task<ImportOutcome> ImportPdfAsync(string path, bool allowDuplicate)
    {
        PdfTextExtractor.ExtractionResult extraction;
        try
        {
            extraction = PdfTextExtractor.Extract(path);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure(ex.Message);
        }

        // 先落盘快照，再入库；入库失败时清理落盘文件。
        var destination = Path.Combine(_snapshotsDirectory, $"{Guid.NewGuid():N}.pdf");
        try
        {
            File.Copy(path, destination, overwrite: false);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure($"无法复制 PDF 快照：{ex.Message}");
        }

        var fingerprint = extraction.Text is null ? null : TextReading.Fingerprint(extraction.Text);
        if (!allowDuplicate)
        {
            var existing = await _database.FindExistingDraftAsync(path, fingerprint).ConfigureAwait(false);
            if (existing is not null)
            {
                TryDelete(destination);
                return new ImportOutcome.Duplicate(existing);
            }
        }

        var draft = new Draft
        {
            Title = Path.GetFileNameWithoutExtension(path),
            Content = extraction.Text,
            IsEditable = false,
            HasExtractableText = extraction.HasSelectableText,
            SourceType = SourceType.Pdf,
            SourceLocation = path,
            SourceLabel = Path.GetFileName(path),
            SnapshotFileURL = destination,
            Fingerprint = fingerprint,
        };
        try
        {
            await _database.InsertDraftAsync(draft, initialVersion: true).ConfigureAwait(false);
            return new ImportOutcome.Success(draft);
        }
        catch (Exception ex)
        {
            TryDelete(destination);
            return new ImportOutcome.Failure($"保存失败：{ex.Message}");
        }
    }

    internal static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* 清理失败不影响结果 */ }
    }
}

/// <summary>
/// PDF 文本提取（R-001/R-002 基础）：PdfPig（Apache-2.0）实现，可选中文字的 PDF
/// 参与关联；扫描版/无文字 PDF 仍保留快照供阅读，但标记"无可用于关联的文字"。
/// 对齐 Mac PDFTextExtractor.swift 口径（&lt;20 字符视为无可用正文）。
/// </summary>
public static class PdfTextExtractor
{
    public sealed record ExtractionResult(string? Text, int PageCount, bool HasSelectableText);

    /// <summary>低于该字符数视为无可用正文。</summary>
    internal const int MinimumExtractableCharacters = 20;

    public static ExtractionResult Extract(string path)
    {
        using var document = UglyToad.PdfPig.PdfDocument.Open(path);
        return Extract(document);
    }

    public static ExtractionResult Extract(byte[] data)
    {
        using var document = UglyToad.PdfPig.PdfDocument.Open(data);
        return Extract(document);
    }

    private static ExtractionResult Extract(UglyToad.PdfPig.PdfDocument document)
    {
        var pieces = new List<string>();
        foreach (var page in document.GetPages())
        {
            var pageText = page.Text;
            if (!string.IsNullOrEmpty(pageText)) pieces.Add(pageText);
        }
        var text = string.Join("\n\n", pieces).Trim(' ', '\t', '\r', '\n', '　');
        var hasText = text.Length >= MinimumExtractableCharacters;
        return new ExtractionResult(hasText ? text : null, document.NumberOfPages, hasText);
    }
}
