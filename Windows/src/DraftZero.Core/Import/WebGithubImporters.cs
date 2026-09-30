using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DraftZero.Core;

/// <summary>
/// 网页正文提取（R-002）：去脚本/样式与明显导航页脚后保留标题与正文。
/// 对齐 Mac WebPageExtractor.swift 的启发式口径（标签剔除 + 实体解码 + 最短正文）。
/// Mac 用 NSAttributedString 渲染；Windows 用 HtmlAgility 式正则剔除 + 实体解码，
/// 共享 fixture 逐例对齐（同批剔除标签清单与 <50 字判定）。
/// </summary>
public static class WebPageExtractor
{
    public record Page(string Title, string Text);

    /// <summary>提取结果正文低于该字符数视为无可读正文。</summary>
    internal const int MinimumBodyCharacters = 50;

    internal static readonly string[] StrippedTags =
        ["script", "style", "nav", "header", "footer", "aside", "noscript", "form"];

    public static Page? Extract(byte[] htmlData)
    {
        var html = Decode(htmlData);
        if (html is null) return null;
        var title = ExtractTitle(html);

        foreach (var tag in StrippedTags)
        {
            html = RemoveTag(tag, html);
        }

        // 去掉所有标签后解码实体，折叠空白。
        var text = Regex.Replace(html, @"<[^>]*>", " ");
        text = DecodeHtmlEntities(text);
        text = text.Replace('\u00A0', ' ');
        text = Regex.Replace(text, @"[ \t]+", " ");
        text = Regex.Replace(text, @" ?\n ?", "\n");
        text = Regex.Replace(text, @"\n{2,}", "\n\n");
        text = text.Trim(' ', '\t', '\r', '\n', '　');
        if (text.Length < MinimumBodyCharacters) return null;
        return new Page(title, text);
    }

    internal static string? Decode(byte[] data)
    {
        try
        {
            var strict = new UTF8Encoding(false, true);
            return strict.GetString(data);
        }
        catch (DecoderFallbackException)
        {
        }
        try
        {
            return Encoding.GetEncoding("GB18030").GetString(data);
        }
        catch
        {
            return null;
        }
    }

    internal static string ExtractTitle(string html)
    {
        var match = Regex.Match(html, @"<title[^>]*>(.*?)</title>",
            RegexOptions.IgnoreCase | RegexOptions.Singleline);
        if (!match.Success) return "";
        var raw = match.Groups[1].Value.Trim(' ', '\t', '\r', '\n');
        return DecodeHtmlEntities(raw);
    }

    /// <summary>标题里的 HTML 实体（&amp; 等）需要解码后展示。</summary>
    internal static string DecodeHtmlEntities(string chunk)
    {
        if (!chunk.Contains('&')) return chunk;
        var sb = new StringBuilder(chunk.Length);
        int i = 0;
        while (i < chunk.Length)
        {
            if (chunk[i] == '&')
            {
                int semi = chunk.IndexOf(';', i, Math.Min(12, chunk.Length - i));
                if (semi > i + 1)
                {
                    var entity = chunk.Substring(i + 1, semi - i - 1);
                    var decoded = DecodeEntity(entity);
                    if (decoded is not null)
                    {
                        sb.Append(decoded);
                        i = semi + 1;
                        continue;
                    }
                }
            }
            sb.Append(chunk[i]);
            i++;
        }
        return sb.ToString();
    }

    private static char? DecodeEntity(string entity)
    {
        if (entity.StartsWith("#x", StringComparison.OrdinalIgnoreCase) || entity.StartsWith("#X"))
        {
            if (int.TryParse(entity[2..], System.Globalization.NumberStyles.HexNumber, null, out var hex)
                && hex > 0 && hex <= 0x10FFFF) return (char)hex;
            return null;
        }
        if (entity.StartsWith('#'))
        {
            if (int.TryParse(entity[1..], out var dec) && dec > 0 && dec <= 0x10FFFF) return (char)dec;
            return null;
        }
        return entity switch
        {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            "nbsp" => '\u00A0',
            "copy" => '©',
            "reg" => '®',
            "trade" => '™',
            "mdash" => '—',
            "ndash" => '–',
            "hellip" => '…',
            "middot" => '·',
            "laquo" => '«',
            "raquo" => '»',
            "times" => '×',
            "divide" => '÷',
            "cent" => '¢',
            "pound" => '£',
            "yen" => '¥',
            "euro" => '€',
            "deg" => '°',
            "plusmn" => '±',
            "para" => '¶',
            "sect" => '§',
            "bull" => '•',
            _ => null,
        };
    }

    internal static string RemoveTag(string tag, string html) =>
        Regex.Replace(html,
            $@"<{tag}[^>]*>[\s\S]*?</{tag}>|<{tag}[^>]*/>",
            "", RegexOptions.IgnoreCase);
}

/// <summary>出站请求统一收口：显式 User-Agent（对齐 Mac HTTPUserAgent.swift 语义）。</summary>
public static class HttpUserAgent
{
    public const string Value = "DraftZero/0.2 (Windows)";

    public static HttpRequestMessage Stamped(HttpRequestMessage request)
    {
        if (!request.Headers.Contains("User-Agent"))
        {
            request.Headers.Add("User-Agent", Value);
        }
        return request;
    }
}

/// <summary>HTTP 请求结果（状态码 + 头 + 内容），可注入替代真实网络。</summary>
public record HttpResult(int StatusCode, IReadOnlyDictionary<string, string> Headers, byte[] Content)
{
    public string? Header(string name) =>
        Headers.TryGetValue(name, out var v) ? v
        : Headers.FirstOrDefault(kv => string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase)).Value;
}

/// <summary>网络层抽象：测试注入，生产走 HttpClient。</summary>
public interface IHttpFetcher
{
    Task<HttpResult> SendAsync(HttpRequestMessage request);
}

public sealed class HttpClientFetcher : IHttpFetcher
{
    public static readonly HttpClientFetcher Shared = new(new HttpClient(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        UseCookies = false,
    })
    {
        Timeout = TimeSpan.FromSeconds(30),
    });

    private readonly HttpClient _client;
    public HttpClientFetcher(HttpClient client) => _client = client;

    public async Task<HttpResult> SendAsync(HttpRequestMessage request)
    {
        using var response = await _client.SendAsync(request).ConfigureAwait(false);
        var content = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var h in response.Headers)
        {
            headers[h.Key] = string.Join(", ", h.Value);
        }
        foreach (var h in response.Content.Headers)
        {
            headers[h.Key] = string.Join(", ", h.Value);
        }
        return new HttpResult((int)response.StatusCode, headers, content);
    }
}

/// <summary>网页快照导入器（R-002）：保存可阅读正文与原 URL；断网后仍可阅读。对齐 Mac WebImporter.swift。</summary>
public sealed class WebImporter
{
    private readonly AppDatabase _database;
    private readonly IHttpFetcher _fetcher;

    public WebImporter(AppDatabase database, IHttpFetcher? fetcher = null)
    {
        _database = database;
        _fetcher = fetcher ?? HttpClientFetcher.Shared;
    }

    public async Task<ImportOutcome> ImportWebPageAsync(Uri url, bool allowDuplicate = false)
    {
        HttpResult response;
        try
        {
            using var request = HttpUserAgent.Stamped(new HttpRequestMessage(HttpMethod.Get, url));
            response = await _fetcher.SendAsync(request).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure($"网络错误，无法读取网页：{ex.Message}");
        }
        if (response.StatusCode is < 200 or >= 300)
        {
            return new ImportOutcome.Failure($"网页返回错误（HTTP {response.StatusCode}）");
        }
        var mime = (response.Header("Content-Type") ?? "").ToLowerInvariant();
        var readable = mime.Contains("text/html") || mime.Contains("text/plain")
            || mime.Contains("xhtml") || mime.Length == 0;
        if (!readable)
        {
            return new ImportOutcome.Failure($"不是可读取的网页（内容类型：{mime}）");
        }

        var page = WebPageExtractor.Extract(response.Content);
        if (page is null)
        {
            return new ImportOutcome.Failure("无法提取正文：可能是登录墙、纯媒体页或非常规页面");
        }

        // 去掉锚点后作为来源标识（同一页面的不同锚点视为同一来源）。
        var normalized = url.Fragment.Length > 0
            ? new Uri(url.AbsoluteUri.Split('#')[0])
            : url;

        var fingerprint = TextReading.Fingerprint(page.Text);
        if (!allowDuplicate)
        {
            var existing = await _database.FindExistingDraftAsync(normalized.AbsoluteUri, fingerprint).ConfigureAwait(false);
            if (existing is not null) return new ImportOutcome.Duplicate(existing);
        }

        var title = page.Title.Length == 0
            ? (url.Host.Length > 0 ? url.Host : "网页快照")
            : page.Title.Length > 80 ? page.Title[..80] : page.Title;
        var draft = new Draft
        {
            Title = title,
            Content = page.Text,
            IsEditable = false,
            SourceType = SourceType.Web,
            SourceLocation = normalized.AbsoluteUri,
            SourceLabel = url.Host,
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
}

/// <summary>GitHub REST/raw 客户端。网络层可注入以便离线测试。对齐 Mac GitHubClient.swift。</summary>
public sealed class GitHubClient
{
    public class GitHubException : Exception
    {
        public GitHubException(string message) : base(message) { }
    }

    public record RepoInfo([property: JsonPropertyName("default_branch")] string DefaultBranch);

    public record TreeEntry(
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("sha")] string Sha,
        [property: JsonPropertyName("size")] int? Size);

    private record TreeResponse(
        [property: JsonPropertyName("sha")] string Sha,
        [property: JsonPropertyName("truncated")] bool? Truncated,
        [property: JsonPropertyName("tree")] List<TreeEntry> Tree);

    private record CommitList([property: JsonPropertyName("sha")] string Sha);

    public IHttpFetcher Fetcher { get; }

    public GitHubClient(IHttpFetcher? fetcher = null) => Fetcher = fetcher ?? HttpClientFetcher.Shared;

    private async Task<byte[]> GetAsync(Uri url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("User-Agent", "DraftZero/0.2");
        request.Headers.Add("Accept", "application/vnd.github+json");
        var response = await Fetcher.SendAsync(request).ConfigureAwait(false);
        switch (response.StatusCode)
        {
            case >= 200 and < 300:
                return response.Content;
            case 403 or 429:
                throw new GitHubException("GitHub 服务限制（未认证请求每小时 60 次），请稍后重试");
            case 404 or 301:
                throw new GitHubException("仓库或文件不存在、已失效，或为私有内容");
            case 451:
                throw new GitHubException("GitHub 返回错误（HTTP 451）");
            default:
                throw new GitHubException($"GitHub 返回错误（HTTP {response.StatusCode}）");
        }
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>默认分支。ref 已知时跳过。</summary>
    public async Task<string> DefaultBranchAsync(string owner, string repo)
    {
        var info = await GetAsync(new Uri($"https://api.github.com/repos/{owner}/{repo}")).ConfigureAwait(false);
        var decoded = JsonSerializer.Deserialize<RepoInfo>(info, JsonOpts);
        if (decoded?.DefaultBranch is null) throw new GitHubException("GitHub 返回了无法解析的数据");
        return decoded.DefaultBranch;
    }

    /// <summary>仓库文件树（含截断标记，R-002"列表不完整"）。</summary>
    public async Task<(string TreeSha, List<TreeEntry> Entries, bool Truncated)> ListTreeAsync(string owner, string repo, string refName)
    {
        var data = await GetAsync(new Uri($"https://api.github.com/repos/{owner}/{repo}/git/trees/{refName}?recursive=1")).ConfigureAwait(false);
        var decoded = JsonSerializer.Deserialize<TreeResponse>(data, JsonOpts);
        if (decoded?.Tree is null) throw new GitHubException("GitHub 返回了无法解析的数据");
        return (decoded.Sha, decoded.Tree, decoded.Truncated ?? false);
    }

    /// <summary>单文件所读版本的标识：该路径最近一次提交的 SHA。</summary>
    public async Task<string> LatestCommitShaAsync(string owner, string repo, string refName, string path)
    {
        var encoded = Uri.EscapeDataString(path).Replace("%2F", "/");
        var data = await GetAsync(new Uri($"https://api.github.com/repos/{owner}/{repo}/commits?path={encoded}&sha={refName}&per_page=1")).ConfigureAwait(false);
        var list = JsonSerializer.Deserialize<List<CommitList>>(data, JsonOpts);
        if (list is null || list.Count == 0) throw new GitHubException("GitHub 返回了无法解析的数据");
        return list[0].Sha;
    }

    /// <summary>下载文件原始内容（raw 域名，不受 API 限额约束）。</summary>
    public async Task<byte[]> DownloadRawAsync(string owner, string repo, string refName, string path)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get,
            new Uri($"https://raw.githubusercontent.com/{owner}/{repo}/{refName}/{path}"));
        var response = await Fetcher.SendAsync(request).ConfigureAwait(false);
        if (response.StatusCode is < 200 or >= 300)
        {
            if (response.StatusCode == 404)
            {
                throw new GitHubException("仓库或文件不存在、已失效，或为私有内容");
            }
            throw new GitHubException($"GitHub 返回错误（HTTP {response.StatusCode}）");
        }
        return response.Content;
    }
}

/// <summary>GitHub 链接解析：仓库、tree（含子目录）、blob 单文件。对齐 Mac GitHubLinkParser.swift。</summary>
public static class GitHubLinkParser
{
    public enum LinkKind { Repo, File }

    public record Ref(LinkKind Kind, string Owner, string Repo, string? RefName, string? Path);

    public static Ref? Parse(string raw)
    {
        var trimmed = raw.Trim(' ', '\t', '\r', '\n');
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url)) return null;
        if (!string.Equals(url.Host, "github.com", StringComparison.OrdinalIgnoreCase)) return null;
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (parts.Count < 2) return null;
        var owner = parts[0];
        var repo = parts[1];
        if (parts.Count == 2 && repo.EndsWith(".git"))
        {
            repo = repo[..^4];
        }
        if (parts.Count > 2)
        {
            switch (parts[2])
            {
                case "blob":
                    if (parts.Count < 5) return null;
                    return new Ref(LinkKind.File, owner, repo, parts[3], string.Join('/', parts.Skip(4)));
                case "tree":
                    if (parts.Count < 4) return null;
                    return new Ref(LinkKind.Repo, owner, repo, parts[3],
                        parts.Count > 4 ? string.Join('/', parts.Skip(4)) : null);
                default:
                    return null;
            }
        }
        return new Ref(LinkKind.Repo, owner, repo, null, null);
    }
}

/// <summary>
/// GitHub 文件导入器：文本入库存为只读快照，PDF 落盘快照。
/// 来源路径为 blob URL，版本标识为 tree SHA（批量）或 commit SHA（单文件）。
/// </summary>
public sealed class GitHubImporter
{
    public const int MaxTextFileSize = 2_000_000;

    private readonly AppDatabase _database;
    private readonly string _snapshotsDirectory;
    public GitHubClient Client { get; }

    public GitHubImporter(AppDatabase database, string snapshotsDirectory, GitHubClient? client = null)
    {
        _database = database;
        _snapshotsDirectory = snapshotsDirectory;
        Client = client ?? new GitHubClient();
    }

    /// <summary>仓库批量（从勾选列表进入，tree SHA 已知）。</summary>
    public Task<ImportOutcome> ImportFileAsync(GitHubImportRequest request, bool allowDuplicate = false) =>
        ImportFileAsync(request, request.TreeSha, allowDuplicate);

    private async Task<ImportOutcome> ImportFileAsync(GitHubImportRequest request, string versionSha, bool allowDuplicate)
    {
        if (!LocalFileImporter.SupportedExtensions.Contains(request.FileExtension))
        {
            return new ImportOutcome.Failure($"不支持的文件类型：{request.Path}");
        }
        byte[] data;
        try
        {
            data = await Client.DownloadRawAsync(request.Owner, request.Repo, request.Branch, request.Path).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure(ex.Message);
        }
        return await StoreAsync(data, request, versionSha, allowDuplicate).ConfigureAwait(false);
    }

    /// <summary>单文件链接（版本标识取最近提交 SHA）。</summary>
    public async Task<ImportOutcome> ImportSingleFileAsync(GitHubLinkParser.Ref refSpec, bool allowDuplicate = false)
    {
        if (refSpec.Kind != GitHubLinkParser.LinkKind.File || refSpec.Path is null)
        {
            return new ImportOutcome.Failure("不是 GitHub 单文件链接");
        }
        try
        {
            var branch = refSpec.RefName ?? await Client.DefaultBranchAsync(refSpec.Owner, refSpec.Repo).ConfigureAwait(false);
            var commitSha = await Client.LatestCommitShaAsync(refSpec.Owner, refSpec.Repo, branch, refSpec.Path).ConfigureAwait(false);
            var data = await Client.DownloadRawAsync(refSpec.Owner, refSpec.Repo, branch, refSpec.Path).ConfigureAwait(false);
            var request = new GitHubImportRequest
            {
                Owner = refSpec.Owner, Repo = refSpec.Repo, Branch = branch,
                TreeSha = commitSha, Path = refSpec.Path, BlobSha = commitSha,
            };
            return await StoreAsync(data, request, commitSha, allowDuplicate).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return new ImportOutcome.Failure(ex.Message);
        }
    }

    private async Task<ImportOutcome> StoreAsync(byte[] data, GitHubImportRequest request, string versionSha, bool allowDuplicate)
    {
        var sourceLocation = request.BlobUrl;
        if (request.FileExtension == "pdf")
        {
            PdfTextExtractor.ExtractionResult extraction;
            try
            {
                extraction = PdfTextExtractor.Extract(data);
            }
            catch
            {
                return new ImportOutcome.Failure($"不是可读取的 PDF：{request.Path}");
            }
            var hasText = extraction.HasSelectableText;

            var destination = Path.Combine(_snapshotsDirectory, $"{Guid.NewGuid():N}.pdf");
            try
            {
                await File.WriteAllBytesAsync(destination, data).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                return new ImportOutcome.Failure($"无法保存 PDF 快照：{ex.Message}");
            }
            var fingerprint = hasText ? TextReading.Fingerprint(extraction.Text!) : null;
            if (!allowDuplicate)
            {
                var existing = await _database.FindExistingDraftAsync(sourceLocation, fingerprint).ConfigureAwait(false);
                if (existing is not null)
                {
                    LocalFileImporter.TryDelete(destination);
                    return new ImportOutcome.Duplicate(existing);
                }
            }
            var pdfDraft = new Draft
            {
                Title = Path.GetFileName(request.Path),
                Content = hasText ? extraction.Text : null,
                IsEditable = false,
                HasExtractableText = hasText,
                SourceType = SourceType.GitHubFile,
                SourceLocation = sourceLocation,
                SourceLabel = $"{request.Owner}/{request.Repo}：{request.Path}",
                SnapshotFileURL = destination,
                Fingerprint = fingerprint,
                SourceVersionSha = versionSha,
            };
            try
            {
                await _database.InsertDraftAsync(pdfDraft, initialVersion: true).ConfigureAwait(false);
                return new ImportOutcome.Success(pdfDraft);
            }
            catch (Exception ex)
            {
                LocalFileImporter.TryDelete(destination);
                return new ImportOutcome.Failure($"保存失败：{ex.Message}");
            }
        }

        // 文本文件：UTF-8 优先，GB18030 回退。
        var text = WebPageExtractor.Decode(data);
        if (text is null)
        {
            return new ImportOutcome.Failure($"无法识别文件编码：{request.Path}");
        }
        if (string.IsNullOrWhiteSpace(text))
        {
            return new ImportOutcome.Failure($"文件没有可读取的正文：{request.Path}");
        }

        var fp = TextReading.Fingerprint(text);
        if (!allowDuplicate)
        {
            var existing = await _database.FindExistingDraftAsync(sourceLocation, fp).ConfigureAwait(false);
            if (existing is not null) return new ImportOutcome.Duplicate(existing);
        }

        var draft = new Draft
        {
            Title = TextReading.ExtractTitle(text, Path.GetFileName(request.Path)),
            Content = text,
            IsEditable = false,
            SourceType = SourceType.GitHubFile,
            SourceLocation = sourceLocation,
            SourceLabel = $"{request.Owner}/{request.Repo}：{request.Path}",
            Fingerprint = fp,
            SourceVersionSha = versionSha,
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
}
