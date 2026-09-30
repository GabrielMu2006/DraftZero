using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DraftZero.Core;

/// <summary>远程分析建议（R-010）：仅作建议，不自动确认归类。</summary>
public record RemoteSuggestion
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Provider { get; init; }
    public string? Model { get; init; }
    /// <summary>JSON 编码的 [UUID]：建议同组的草稿。</summary>
    public string? DraftIdsData { get; init; }
    public string? Explanation { get; init; }
    /// <summary>JSON 编码的 [RemoteCitation]，已通过原文校验。</summary>
    public string? CitationsData { get; init; }
    /// <summary>截断等服务限制说明（R-010"仅分析了部分文字"）。</summary>
    public string? Notice { get; init; }
    public DateTime CreatedAt { get; init; } = DateTime.UtcNow;
    public bool Dismissed { get; set; }

    [JsonIgnore]
    public List<Guid> DraftIds
    {
        get
        {
            if (DraftIdsData is null) return [];
            try
            {
                return JsonSerializer.Deserialize<List<Guid>>(DraftIdsData) ?? [];
            }
            catch (JsonException)
            {
                return [];
            }
        }
    }

    [JsonIgnore]
    public List<RemoteCitation> Citations
    {
        get
        {
            if (CitationsData is null) return [];
            try
            {
                return JsonSerializer.Deserialize<List<RemoteCitation>>(CitationsData) ?? [];
            }
            catch (JsonException)
            {
                return [];
            }
        }
    }
}

/// <summary>引用片段：远程结果要展示为依据，必须先通过原文校验。</summary>
public record RemoteCitation(Guid DraftId, string Quote);

/// <summary>提供方返回的分组提案（解析与校验的中间产物）。</summary>
public record RemoteGroupProposal(List<Guid> DraftIds, string Reason, List<RemoteCitation> Citations);

public class RemoteAnalysisException : Exception
{
    public RemoteAnalysisException(string message) : base(message) { }
}

/// <summary>远程分析的抽象（R-010：V1 只提供 DeepSeek，但保留替换提供方的能力）。</summary>
public interface IRemoteAnalysisProvider
{
    string Identifier { get; }
    Task<(List<RemoteGroupProposal> Proposals, string? Notice)> AnalyzeProjectCandidatesAsync(
        IReadOnlyList<(Guid Id, string Title, string Text)> drafts);
}

/// <summary>
/// DeepSeek 提供方（R-010）。只发送标题与正文节选，绝不上传原始文件或本机路径；
/// 网络层可注入以便离线测试。对齐 Mac DeepSeekProvider.swift（截断预算、错误映射、引用校验）。
/// </summary>
public sealed class DeepSeekProvider : IRemoteAnalysisProvider
{
    public static readonly Uri DefaultEndpoint = new("https://api.deepseek.com/chat/completions");
    /// <summary>每份草稿正文节选上限与总预算（R-010"超出服务限制时说明仅分析了部分文字"）。</summary>
    public const int PerDraftCharacterLimit = 1500;
    public const int TotalCharacterBudget = 12000;

    /// <summary>模型名会随服务方变化（SPEC §7），不写成永久产品规则；调用方可覆盖。</summary>
    public string Model { get; }
    public Uri Endpoint { get; }
    public string ApiKey { get; }
    public IHttpFetcher Fetcher { get; }

    public string Identifier => "deepseek";

    public DeepSeekProvider(string apiKey, string model = "deepseek-chat",
        Uri? endpoint = null, IHttpFetcher? fetcher = null)
    {
        ApiKey = apiKey;
        Model = model;
        Endpoint = endpoint ?? DefaultEndpoint;
        Fetcher = fetcher ?? HttpClientFetcher.Shared;
    }

    private sealed record ChatResponse(List<ChatChoice>? Choices);

    private sealed record ChatChoice(ChatMessage? Message);

    private sealed record ChatMessage(string Role, string Content);

    internal sealed record GroupsPayload(List<PayloadGroup>? Groups);

    internal sealed record PayloadGroup(
        [property: JsonPropertyName("draft_ids")] List<int>? DraftIds,
        [property: JsonPropertyName("reason")] string? Reason,
        [property: JsonPropertyName("citations")] List<PayloadCitation>? Citations);

    internal sealed record PayloadCitation(
        [property: JsonPropertyName("draft_index")] int DraftIndex,
        [property: JsonPropertyName("quote")] string Quote);

    private sealed record ChatRequestBody(string Model, List<ChatMessage> Messages, double Temperature, RF ResponseFormat);

    private sealed record RF(string Type);

    internal const string SystemPrompt = """
        你是草稿归类助手。仅依据给出的草稿文本判断哪些草稿可能属于同一个想法项目。输出 JSON：\
        {"groups":[{"draft_ids":[编号],"reason":"一句话理由","citations":[{"draft_index":编号,"quote":"原文片段"}]}]}。\
        规则：1) 编号必须是给出的草稿编号；2) 每条 quote 必须逐字摘自对应草稿原文；\
        3) 证据不足就不要分组；4) 不要编造共同关键词或因果关系；5) 不要输出 JSON 以外的内容。
        """;

    internal (string Prompt, bool Truncated) UserPrompt(IReadOnlyList<(Guid Id, string Title, string Text)> drafts)
    {
        var budget = TotalCharacterBudget;
        var truncated = false;
        var lines = new List<string>();
        for (int index = 0; index < drafts.Count; index++)
        {
            var draft = drafts[index];
            var body = draft.Text.Trim(' ', '\t', '\r', '\n', '　');
            if (body.Length > PerDraftCharacterLimit)
            {
                body = body[..PerDraftCharacterLimit];
                truncated = true;
            }
            if (body.Length > budget)
            {
                body = body[..Math.Max(0, budget)];
                truncated = true;
            }
            budget -= body.Length;
            lines.Add($"草稿 {index}：{draft.Title}\n{body}");
        }
        return ("以下是待分析的草稿：\n\n" + string.Join("\n\n", lines) + "\n\n请给出可能的分组。", truncated);
    }

    public async Task<(List<RemoteGroupProposal> Proposals, string? Notice)> AnalyzeProjectCandidatesAsync(
        IReadOnlyList<(Guid Id, string Title, string Text)> drafts)
    {
        if (drafts.Count < 2) return ([], null); // 单份草稿没有可分组对象
        var (prompt, truncated) = UserPrompt(drafts);

        var body = JsonSerializer.Serialize(new ChatRequestBody(
            Model,
            [new ChatMessage("system", SystemPrompt), new ChatMessage("user", prompt)],
            0.2,
            new RF("json_object")));

        HttpResult response;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("Authorization", $"Bearer {ApiKey}");
            HttpUserAgent.Stamped(request);
            response = await Fetcher.SendAsync(request).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new RemoteAnalysisException($"网络错误，无法连接远程服务：{ex.Message}");
        }
        switch (response.StatusCode)
        {
            case >= 200 and < 300: break;
            case 401: throw new RemoteAnalysisException("API Key 无效，请检查设置");
            case 402: throw new RemoteAnalysisException("DeepSeek 账户余额不足，请充值后重试");
            case 429: throw new RemoteAnalysisException("请求过于频繁或触发限流，请稍后重试");
            default: throw new RemoteAnalysisException($"远程服务出错（HTTP {response.StatusCode}），请稍后重试");
        }

        ChatResponse chat;
        try
        {
            chat = JsonSerializer.Deserialize<ChatResponse>(response.Content, JsonOpts)
                ?? throw new RemoteAnalysisException("远程服务返回了无法解析的结果");
        }
        catch (JsonException)
        {
            throw new RemoteAnalysisException("远程服务返回了无法解析的结果");
        }
        var content = chat.Choices?.FirstOrDefault()?.Message?.Content
            ?? throw new RemoteAnalysisException("远程服务返回了无法解析的结果");
        var payload = ParseGroupsPayload(content);

        var idByIndex = drafts.Select(d => d.Id).ToList();
        var contents = drafts.ToDictionary(d => d.Id, d => d.Text);
        var proposals = new List<RemoteGroupProposal>();
        foreach (var group in payload.Groups ?? [])
        {
            var ids = (group.DraftIds ?? [])
                .Where(i => i >= 0 && i < idByIndex.Count)
                .Select(i => idByIndex[i])
                .ToList();
            if (ids.Count < 2) continue; // 单草稿"分组"没有意义
            // 引用校验：quote 必须能在对应草稿原文（归一化后）中找到，否则丢弃该引用；
            // 一条有效引用都没有的分组不展示（R-010：必须引用实际草稿片段才能展示为依据）。
            var validCitations = (group.Citations ?? []).Select(citation =>
            {
                if (citation.DraftIndex < 0 || citation.DraftIndex >= idByIndex.Count) return null;
                var draftId = idByIndex[citation.DraftIndex];
                var text = contents.GetValueOrDefault(draftId, "");
                return QuoteMatches(citation.Quote, text)
                    ? new RemoteCitation(draftId, citation.Quote)
                    : null;
            }).Where(c => c is not null).Cast<RemoteCitation>().ToList();
            if (validCitations.Count == 0) continue;
            proposals.Add(new RemoteGroupProposal(ids.Distinct().ToList(), group.Reason ?? "", validCitations));
        }

        string? notice = truncated
            ? $"草稿较长，仅发送了每个草稿的前 {PerDraftCharacterLimit} 字参与分析"
            : null;
        return (proposals, notice);
    }

    /// <summary>模型输出可能带 ```json 围栏，剥离后再解析；解析失败视为 badResponse。</summary>
    internal static GroupsPayload ParseGroupsPayload(string content)
    {
        var json = content.Trim(' ', '\t', '\r', '\n', '`');
        if (content.TrimStart().StartsWith("```"))
        {
            var body = content.TrimStart();
            int firstNewline = body.IndexOf('\n');
            if (firstNewline >= 0) body = body[(firstNewline + 1)..];
            body = body.TrimEnd('`');
            json = body.Trim(' ', '\t', '\r', '\n');
        }
        try
        {
            var payload = JsonSerializer.Deserialize<GroupsPayload>(json, JsonOpts);
            return payload ?? throw new RemoteAnalysisException("远程服务返回了无法解析的结果");
        }
        catch (JsonException)
        {
            throw new RemoteAnalysisException("远程服务返回了无法解析的结果");
        }
    }

    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    /// <summary>引用校验：归一化后取子串；模型偶尔会截短引文，回退为前缀匹配。</summary>
    public static bool QuoteMatches(string quote, string text)
    {
        static string Normalize(string s)
        {
            var sb = new StringBuilder(s.Length);
            foreach (var rune in s.EnumerateRunes())
            {
                if (Rune.IsLetter(rune) || Rune.IsNumber(rune) || System.Globalization.UnicodeCategory.NonSpacingMark == Rune.GetUnicodeCategory(rune) || System.Globalization.UnicodeCategory.SpacingCombiningMark == Rune.GetUnicodeCategory(rune) || System.Globalization.UnicodeCategory.EnclosingMark == Rune.GetUnicodeCategory(rune))
                {
                    sb.Append(Rune.ToLowerInvariant(rune).ToString());
                }
            }
            return sb.ToString();
        }
        var nQuote = Normalize(quote);
        var nText = Normalize(text);
        if (nQuote.Length < 8) return false; // 过短的"引用"没有证据价值
        if (nText.Contains(nQuote, StringComparison.Ordinal)) return true;
        var prefix = nQuote[..Math.Min(nQuote.Length, 20)];
        return nText.Contains(prefix, StringComparison.Ordinal);
    }
}

/// <summary>远程建议的存取（R-010）。建议不创建任何已确认关系。</summary>
public static class RemoteSuggestionStore
{
    public static Task SaveRemoteSuggestionAsync(this AppDatabase db, RemoteSuggestion suggestion) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, """
                INSERT INTO remoteSuggestion (id,provider,model,draftIdsData,explanation,citationsData,notice,createdAt,dismissed)
                VALUES (@id,@provider,@model,@draftIds,@explanation,@citations,@notice,@createdAt,0)
                """,
                Db.P("@id", Db.Uid(suggestion.Id)),
                Db.P("@provider", suggestion.Provider),
                Db.P("@model", suggestion.Model),
                Db.P("@draftIds", suggestion.DraftIdsData),
                Db.P("@explanation", suggestion.Explanation),
                Db.P("@citations", suggestion.CitationsData),
                Db.P("@notice", suggestion.Notice),
                Db.P("@createdAt", Db.Fmt(suggestion.CreatedAt)));
            return Task.CompletedTask;
        });

    public static async Task<List<RemoteSuggestion>> PendingRemoteSuggestionsAsync(this AppDatabase db, string? provider = null) =>
        await db.WriteAsync(conn =>
        {
            var sql = "SELECT * FROM remoteSuggestion WHERE dismissed=0";
            var args = new List<Microsoft.Data.Sqlite.SqliteParameter>();
            if (provider is not null)
            {
                sql += " AND provider=@provider";
                args.Add(Db.P("@provider", provider));
            }
            sql += " ORDER BY createdAt DESC";
            return Task.FromResult(Db.ReadRows(conn, sql, args.ToArray()).Select(Read).ToList());
        }).ConfigureAwait(false);

    public static Task DismissRemoteSuggestionAsync(this AppDatabase db, Guid id) =>
        db.WriteAsync(conn =>
        {
            Db.Exec(conn, "UPDATE remoteSuggestion SET dismissed=1 WHERE id=@id", Db.P("@id", Db.Uid(id)));
            return Task.CompletedTask;
        });

    private static RemoteSuggestion Read(Dictionary<string, object?> r) => new()
    {
        Id = Db.Uid(Db.Str(r, "id")!),
        Provider = Db.Str(r, "provider") ?? "",
        Model = Db.Str(r, "model"),
        DraftIdsData = Db.Str(r, "draftIdsData"),
        Explanation = Db.Str(r, "explanation"),
        CitationsData = Db.Str(r, "citationsData"),
        Notice = Db.Str(r, "notice"),
        CreatedAt = Db.ParseTime(Db.Str(r, "createdAt")) ?? DateTime.UtcNow,
        Dismissed = Db.Int(r, "dismissed") != 0,
    };
}
