using CommunityToolkit.Mvvm.ComponentModel;
using DraftZero.App.Services;
using DraftZero.Core;
using System.Collections.ObjectModel;
using System.Text.Json;

namespace DraftZero.App;

/// <summary>导入批次单项（R-001 逐项报告）。</summary>
public partial class ImportItemRow : ObservableObject
{
    public abstract record ItemSource;
    public record LocalFileSource(string Path) : ItemSource;
    public record WebPageSource(string Url) : ItemSource;
    public record GitHubFileSource(GitHubImportRequest Request) : ItemSource;

    public enum ImportItemStatus { Pending, Running, Success, Duplicate, Failed }

    public Guid Id { get; init; }
    public required string DisplayName { get; init; }
    public ItemSource? Source { get; init; }
    public string? ExistingTitle { get; set; }
    public string? FailureReason { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(DisplayStatus))]
    private ImportItemStatus _status = ImportItemStatus.Pending;

    public bool IsDuplicate => Status == ImportItemStatus.Duplicate;

    public string DisplayStatus => Status switch
    {
        ImportItemStatus.Pending => "等待",
        ImportItemStatus.Running => "导入中…",
        ImportItemStatus.Success => "已导入",
        ImportItemStatus.Duplicate => $"重复：已有「{ExistingTitle}」",
        ImportItemStatus.Failed => $"失败：{FailureReason}",
        _ => "",
    };

    public static ImportItemStatus ToStatus(ImportOutcome outcome) => outcome switch
    {
        ImportOutcome.Success => ImportItemStatus.Success,
        ImportOutcome.Duplicate d => ImportItemStatus.Duplicate,
        ImportOutcome.Failure f => ImportItemStatus.Failed,
        _ => ImportItemStatus.Failed,
    };
}

/// <summary>仓库文件浏览状态（R-002）。</summary>
public partial class RepoBrowseState : ObservableObject
{
    public required string Owner { get; init; }
    public required string Repo { get; init; }
    public required string Branch { get; init; }
    public required string TreeSha { get; init; }
    public required List<RepoEntryRow> Entries { get; init; }
    public required bool Truncated { get; init; }

    [ObservableProperty] private HashSet<string> _checked = [];
}

public partial class RepoEntryRow : ObservableObject
{
    public required string Path { get; init; }
    public required int Size { get; init; }
    public required string BlobSha { get; init; }
    public required bool IsSupported { get; init; }
    public required bool IsTooLarge { get; init; }

    public string SizeLabel => Size < 1024 ? $"{Size} B"
        : Size < 1_048_576 ? $"{Size / 1024.0:0} KB"
        : $"{Size / 1_048_576.0:0.0} MB";
}

/// <summary>外部 draftzero:// 写入型深链的待确认请求（W-009）。</summary>
public partial class PendingDeepLinkWrite
{
    public required string Title { get; init; }
    public required string Message { get; init; }
    public required Func<Task> Action { get; init; }
}

/// <summary>语义子系统与归类裁决（Mac SemanticModel.swift 的移植）。</summary>
public partial class AppViewModel
{
    public async Task BootstrapSemanticAsync()
    {
        if (_database is null || _candidateEngine is not null) return;
        try
        {
            // 模型加载（读 470MB 文件 + 建 ONNX 会话）是重活，移出 UI 线程
            var engine = await Task.Run(() =>
            {
                var modelLocator = ModelLocator.Locate();
                var tokenizer = new HuggingFaceTokenizerAdapter(modelLocator.TokenizerJsonPath);
                return new E5OnnxEmbedder(modelLocator.ModelOnnxPath, (ITokenizerAdapter)tokenizer);
            });
            _embedder = engine;
            _candidateEngine = new CandidateEngine(_database, engine);
        }
        catch (Exception ex)
        {
            SemanticState = SemanticUiState.Degraded;
            SemanticStateDetail = $"语义线索暂不可用（{ex.Message}），当前只显示关键词线索";
            return;
        }
        await RefreshSemanticAsync();
    }

    /// <summary>增量索引 + 重新生成候选；内容未变的部分自动跳过。
    /// 索引中重复触发直接忽略（防导入风暴下的并发重建）。</summary>
    public async Task RefreshSemanticAsync()
    {
        if (_candidateEngine is null || _database is null) return;
        if (SemanticState == SemanticUiState.Indexing) return;
        SemanticState = SemanticUiState.Indexing;
        var drafts = await _database.DraftsAsync();
        try
        {
            // 分词/推理/候选成组是 CPU 密集：移出 UI 线程；await 后回到 UI 上下文再更新属性
            var engine = _candidateEngine;
            ClueReport = await Task.Run(() => engine.RefreshAsync(drafts));
            SemanticState = SemanticUiState.Ready;
        }
        catch (Exception ex)
        {
            SemanticState = SemanticUiState.Degraded;
            SemanticStateDetail = $"索引失败（{ex.Message}），可在设置中重建索引";
        }
        await LoadQueuesAsync();
    }

    public async Task LoadQueuesAsync()
    {
        if (_candidateEngine is null) return;
        ReplaceQueue(LeadPairs, await _candidateEngine.QueueAsync(CandidateKind.Lead));
        ReplaceQueue(DuplicatePairs, await _candidateEngine.QueueAsync(CandidateKind.Duplicate));
        ReplaceQueue(DeferredLeads, await _candidateEngine.QueueAsync(CandidateKind.Lead, CandidateStatus.Deferred));
        ReplaceQueue(RejectedLeads, await _candidateEngine.QueueAsync(CandidateKind.Lead, CandidateStatus.Rejected));
        await LoadRemoteSuggestionsAsync();
        OnPropertyChanged(nameof(PendingClueCount));
    }

    private static void ReplaceQueue<T>(ObservableCollection<T> target, IReadOnlyList<T> items)
    {
        target.Clear();
        foreach (var item in items) target.Add(item);
    }

    // ---- 裁决（接受 / 不相关 / 暂缓 / 重新分析） ----

    public async Task AcceptPairAsync(CandidatePair pair, Project project)
    {
        if (_candidateEngine is null) return;
        await _candidateEngine.AcceptAsync(pair.Id, project.Id);
        await LoadQueuesAsync();
        await ReloadAsync();
    }

    public async Task CreateProjectAndAcceptAsync(string name, CandidatePair pair)
    {
        if (_database is null) return;
        var project = await _database.CreateProjectAsync(name);
        await AcceptPairAsync(pair, project);
    }

    public async Task RejectPairAsync(CandidatePair pair)
    {
        if (_candidateEngine is null) return;
        await _candidateEngine.DecideAsync(pair.Id, CandidateStatus.Rejected);
        await LoadQueuesAsync();
    }

    public async Task DeferPairAsync(CandidatePair pair)
    {
        if (_candidateEngine is null) return;
        await _candidateEngine.DecideAsync(pair.Id, CandidateStatus.Deferred);
        await LoadQueuesAsync();
    }

    public async Task ReanalyzePairAsync(CandidatePair pair)
    {
        if (_candidateEngine is null) return;
        await _candidateEngine.ReanalyzeAsync(pair.Id);
        await LoadQueuesAsync();
    }

    /// <summary>索引故障后的完全重建（R-004：故障后可重建索引）。</summary>
    public async Task RebuildSemanticIndexAsync()
    {
        if (_candidateEngine is null || _database is null) return;
        SemanticState = SemanticUiState.Indexing;
        try
        {
            var engine = _candidateEngine;
            await Task.Run(async () =>
            {
                var drafts = await _database.DraftsAsync();
                await SemanticIndexStore.RebuildSemanticIndexAsync(_database, drafts, engine.Embedder);
                await engine.RefreshAsync(await _database.DraftsAsync());
            });
            ClueReport = await engine.CountsAsync();
            SemanticState = SemanticUiState.Ready;
        }
        catch (Exception ex)
        {
            SemanticState = SemanticUiState.Degraded;
            SemanticStateDetail = $"重建索引失败：{ex.Message}";
        }
        await LoadQueuesAsync();
    }
}

/// <summary>远程分析（R-010 / W-008）：默认关闭；Key 存 Windows 用户级受保护存储。</summary>
public partial class AppViewModel
{
    public const string KeychainAccount = "deepseek-api-key";

    private bool HasKey => _secretStore.Read(KeychainAccount) is { Length: > 0 };

    public void RefreshRemoteState()
    {
        RemoteEnabled = RemoteEnabledStore.Load();
        RemoteHasKey = HasKey;
        _remoteProvider = MakeProviderIfPossible();
    }

    /// <summary>未启用或未提供 Key 时返回 null——任何调用路径都不会发送正文（R-010 验收）。</summary>
    private DeepSeekProvider? MakeProviderIfPossible()
    {
        if (!RemoteEnabled) return null;
        var key = _secretStore.Read(KeychainAccount);
        if (string.IsNullOrEmpty(key)) return null;
        return new DeepSeekProvider(key);
    }

    public async Task EnableRemoteAnalysisAsync(string apiKey)
    {
        var trimmed = apiKey.Trim();
        if (trimmed.Length == 0)
        {
            RemoteStatus = "请先填写 API Key";
            return;
        }
        if (!_secretStore.Save(KeychainAccount, trimmed))
        {
            RemoteStatus = "无法保存 Key（受保护存储写入失败）";
            return;
        }
        RemoteEnabledStore.Save(true);
        RefreshRemoteState();
        RemoteStatus = "已启用，新加入的草稿将自动分析";
    }

    public void DisableRemoteAnalysis()
    {
        RemoteEnabledStore.Save(false);
        RefreshRemoteState();
        RemoteStatus = "已关闭，后续草稿不再远程发送";
    }

    public void RemoveRemoteKey()
    {
        RemoteEnabledStore.Save(false);
        _secretStore.Delete(KeychainAccount);
        _remoteProvider = null;
        RefreshRemoteState();
        RemoteStatus = "已移除 API Key 并关闭远程分析";
    }

    public Task AnalyzeAllDraftsRemotelyAsync()
    {
        var withText = Drafts.Where(d => d.HasExtractableText && !string.IsNullOrEmpty(d.Content))
            .Select(d => d.Id).ToHashSet();
        return AnalyzeRemotelyAsync(withText);
    }

    /// <summary>新草稿导入/新建后的自动触发（R-010：启用后自动分析新加入的草稿）。</summary>
    public async Task AnalyzeNewDraftsSinceAsync(HashSet<Guid> previousIds)
    {
        var newIds = Drafts.Select(d => d.Id).ToHashSet();
        newIds.ExceptWith(previousIds);
        if (newIds.Count == 0) return;
        await AnalyzeRemotelyAsync(newIds);
    }

    private async Task AnalyzeRemotelyAsync(HashSet<Guid> draftIds)
    {
        RefreshRemoteState();
        var provider = MakeProviderIfPossible();
        if (provider is null || _database is null) return; // 关闭时静默跳过

        // 新草稿优先；只发标题+正文节选（R-010：不上传路径/文件）。
        var ordered = Drafts
            .OrderBy(d => draftIds.Contains(d.Id) ? 0 : 1)
            .Where(d => d.HasExtractableText && !string.IsNullOrEmpty(d.Content))
            .ToList();
        if (ordered.Count < 2)
        {
            RemoteStatus = "可读取正文的草稿不足两份，暂无远程分组对象";
            return;
        }
        RemoteAnalyzing = true;
        try
        {
            var payload = ordered.Select(d => (d.Id, d.Title, d.Content ?? "")).ToList();
            var (proposals, notice) = await provider.AnalyzeProjectCandidatesAsync(payload);
            var contents = ordered.ToDictionary(d => d.Id, d => d.Content ?? "");
            foreach (var proposal in proposals)
            {
                // 双重校验后落库（提供方内部已校验一次；入库前再按当前正文校验）。
                var validCitations = proposal.Citations
                    .Where(c => DeepSeekProvider.QuoteMatches(c.Quote, contents.GetValueOrDefault(c.DraftId, "")))
                    .ToList();
                if (validCitations.Count == 0 || proposal.DraftIds.Count < 2) continue;
                var suggestion = new RemoteSuggestion
                {
                    Provider = provider.Identifier,
                    Model = provider.Model,
                    DraftIdsData = JsonSerializer.Serialize(proposal.DraftIds),
                    Explanation = proposal.Reason,
                    CitationsData = JsonSerializer.Serialize(validCitations),
                    Notice = notice,
                };
                await _database.SaveRemoteSuggestionAsync(suggestion);
            }
            await LoadRemoteSuggestionsAsync();
            RemoteStatus = proposals.Count == 0
                ? "远程分析完成：未提出新分组"
                : $"远程分析完成：{proposals.Count} 条建议（仅供参考）" + (notice is null ? "" : $" · {notice}");
        }
        catch (Exception ex)
        {
            // 错误不能让本地工作流不可用（R-010）。
            RemoteStatus = ex.Message;
        }
        finally
        {
            RemoteAnalyzing = false;
        }
    }

    public async Task LoadRemoteSuggestionsAsync()
    {
        if (_database is null) return;
        var items = await _database.PendingRemoteSuggestionsAsync();
        RemoteSuggestions.Clear();
        foreach (var s in items) RemoteSuggestions.Add(s);
        OnPropertyChanged(nameof(PendingClueCount));
    }

    public async Task DismissRemoteSuggestionAsync(RemoteSuggestion suggestion)
    {
        if (_database is null) return;
        await _database.DismissRemoteSuggestionAsync(suggestion.Id);
        await LoadRemoteSuggestionsAsync();
    }

    /// <summary>接受远程建议：整组草稿加入项目（与候选接受相同的确认路径；不自动创建）。</summary>
    public async Task AcceptRemoteSuggestionAsync(RemoteSuggestion suggestion, Project project)
    {
        if (_database is null) return;
        foreach (var draftId in suggestion.DraftIds)
        {
            await _database.AddDraftToProjectAsync(draftId, project.Id);
        }
        await _database.DismissRemoteSuggestionAsync(suggestion.Id);
        await LoadRemoteSuggestionsAsync();
        await ReloadAsync();
    }
}

/// <summary>深链路由（W-009：写入型必须应用内确认，拒绝零写入）。</summary>
public partial class AppViewModel
{
    public async Task RouteDeepLinkAsync(Uri url)
    {
        if (!string.Equals(url.Scheme, "draftzero", StringComparison.OrdinalIgnoreCase)) return;
        var host = url.Host.ToLowerInvariant();
        var query = System.Web.HttpUtility.ParseQueryString(url.Query);
        string? Q(string name) => query[name];

        switch (host)
        {
            case "new-draft":
                var title = Q("title");
                if (!string.IsNullOrWhiteSpace(title))
                {
                    var content = Q("content") ?? "";
                    var message = $"来自外部链接的请求要在 Draft Zero 创建草稿「{title}」。";
                    if (content.Length > 0)
                    {
                        message += $"\n内容预览：{string.Concat(content.Take(80))}{(content.Length > 80 ? "…" : "")}";
                    }
                    await GatedWriteAsync("创建草稿", message,
                        () => CreateDraftAsync(title, content));
                }
                else
                {
                    OpenNewDraftPage();
                }
                break;
            case "import":
                var path = Q("path");
                if (!string.IsNullOrEmpty(path))
                {
                    var importPath = Uri.UnescapeDataString(path);
                    await GatedWriteAsync("导入文件", $"来自外部链接的请求要导入本地文件：\n{importPath}",
                        () => ImportFilesAsync([importPath]));
                }
                break;
            case "import-dir":
                var dir = Q("path");
                if (!string.IsNullOrEmpty(dir))
                {
                    var dirPath = Uri.UnescapeDataString(dir);
                    await GatedWriteAsync("批量导入", $"来自外部链接的请求要导入目录中全部受支持文件：\n{dirPath}", async () =>
                    {
                        if (!Directory.Exists(dirPath)) return;
                        var files = Directory.GetFiles(dirPath)
                            .Where(p => !Path.GetFileName(p).StartsWith('.'))
                            .Where(p => LocalFileImporter.SupportedExtensions.Contains(
                                Path.GetExtension(p).TrimStart('.').ToLowerInvariant()))
                            .OrderBy(p => Path.GetFileName(p), StringComparer.Ordinal)
                            .ToList();
                        await ImportFilesAsync(files);
                    });
                }
                break;
            case "tab":
                var tab = url.AbsolutePath.Trim('/').ToLowerInvariant();
                SidebarSelection = tab switch
                {
                    "clues" => SidebarItem.ClueDesk,
                    "projects" => SidebarItem.Projects,
                    "todo" => SidebarItem.Todo,
                    "archived" => SidebarItem.Archived,
                    "settings" => SidebarItem.Settings,
                    _ => SidebarItem.DraftBox,
                };
                break;
            case "project":
                if (url.AbsolutePath == "/new")
                {
                    var name = Q("name");
                    if (!string.IsNullOrEmpty(name))
                    {
                        await GatedWriteAsync("新建项目", $"来自外部链接的请求要创建项目「{name}」。",
                            () => CreateProjectAsync(name));
                        SidebarSelection = SidebarItem.Projects;
                    }
                }
                else if (url.AbsolutePath == "/open")
                {
                    var openName = Q("name");
                    SidebarSelection = SidebarItem.Projects;
                    if (Projects.FirstOrDefault(p => p.Name == openName) is { } openProject)
                    {
                        SelectProject(openProject);
                    }
                }
                break;
            case "status":
                var projectName = Q("project");
                var statusName = Q("status")?.ToLowerInvariant();
                var status = statusName switch
                {
                    "todo" => ProjectStatus.Todo,
                    "inprogress" or "进行中" => ProjectStatus.InProgress,
                    "mostlydone" or "基本完成" => ProjectStatus.MostlyDone,
                    "archived" or "暂时封存" => ProjectStatus.Archived,
                    _ => ProjectStatus.Inbox,
                };
                if (Projects.FirstOrDefault(p => p.Name == projectName) is { } statusProject)
                {
                    await GatedWriteAsync("修改项目状态",
                        $"来自外部链接的请求要把项目「{projectName}」的状态改为「{status.DisplayName()}」。",
                        () => SetProjectStatusAsync(statusProject, status));
                }
                break;
            case "accept-pair":
                if (int.TryParse(Q("index"), out var acceptIndex))
                {
                    var sorted = LeadPairs.Concat(DuplicatePairs).OrderByDescending(p => p.Score).ToList();
                    if (acceptIndex < sorted.Count)
                    {
                        var pair = sorted[acceptIndex];
                        var targetName = Q("project") ?? "待命名线索组";
                        await GatedWriteAsync("接受线索",
                            $"来自外部链接的请求要接受第 {acceptIndex + 1} 条候选线索，并归入项目「{targetName}」（项目不存在时会新建）。",
                            async () =>
                            {
                                if (Projects.FirstOrDefault(p => p.Name == targetName) is { } existing)
                                {
                                    await AcceptPairAsync(pair, existing);
                                }
                                else
                                {
                                    await CreateProjectAndAcceptAsync(targetName, pair);
                                }
                            });
                        SidebarSelection = SidebarItem.ClueDesk;
                    }
                }
                break;
            case "reject-pair":
                if (int.TryParse(Q("index"), out var rejectIndex))
                {
                    var sorted = LeadPairs.Concat(DuplicatePairs).OrderByDescending(p => p.Score).ToList();
                    if (rejectIndex < sorted.Count)
                    {
                        var pair = sorted[rejectIndex];
                        await GatedWriteAsync("标记不相关",
                            $"来自外部链接的请求要把第 {rejectIndex + 1} 条候选线索标记为不相关（草稿与项目不变）。",
                            () => RejectPairAsync(pair));
                        SidebarSelection = SidebarItem.ClueDesk;
                    }
                }
                break;
            case "defer-pair":
                if (int.TryParse(Q("index"), out var deferIndex))
                {
                    var sorted = LeadPairs.Concat(DuplicatePairs).OrderByDescending(p => p.Score).ToList();
                    if (deferIndex < sorted.Count)
                    {
                        var pair = sorted[deferIndex];
                        await GatedWriteAsync("暂缓线索",
                            $"来自外部链接的请求要暂缓第 {deferIndex + 1} 条候选线索（留在稍后处理）。",
                            () => DeferPairAsync(pair));
                        SidebarSelection = SidebarItem.ClueDesk;
                    }
                }
                break;
        }
    }

    /// <summary>写入型深链统一入口：挂起为待确认请求，弹窗确认前绝不触库（W-009）。</summary>
    private async Task GatedWriteAsync(string title, string message, Func<Task> action)
    {
        PendingDeepLinkWrite = new PendingDeepLinkWrite
        {
            Title = title,
            Message = message,
            Action = async () =>
            {
                PendingDeepLinkWrite = null;
                await action();
            },
        };
        await Task.CompletedTask;
    }
}

/// <summary>工作区导出（D-002 双向迁移）：当前工作区 → .dzarchive，供 Mac 导入。</summary>
public partial class AppViewModel
{
    public async Task ExportWorkspaceAsync(string destination)
    {
        if (_database is null) return;
        ExportRunning = true;
        ExportMessage = null;
        try
        {
            IProgress<string> progress = new Progress<string>(msg => ExportMessage = msg);
            var db = _database;
            var result = await Task.Run(() =>
                WorkspaceExporter.ExportAsync(db, destination, progress.Report));
            ExportMessage = $"导出完成：{Path.GetFileName(result.Destination)}（{result.SizeBytes / 1024 / 1024} MB）。" +
                "档案未加密，含草稿正文与 PDF，请妥善保管；在 Mac 版设置中选择该档案导入。";
        }
        catch (Exception ex)
        {
            ExportMessage = $"导出失败：{ex.Message}";
        }
        finally
        {
            ExportRunning = false;
        }
    }
}

/// <summary>迁移导入（W-011）：Windows 首次启动空工作区的一次性导入。</summary>
public partial class AppViewModel
{
    public async Task ImportMacArchiveAsync(string archivePath)
    {
        if (_database is null) return;
        MigrationRunning = true;
        MigrationMessage = null;
        try
        {
            // 校验/写库/落盘是重活：移出 UI 线程；进度经 Progress<T> 回到 UI。
            IProgress<string> progress = new Progress<string>(msg => MigrationMessage = msg);
            var db = _database;
            var counts = await Task.Run(() =>
                WorkspaceImporter.ImportAsync(db, archivePath, progress.Report));
            MigrationMessage = $"导入完成：{counts.Drafts} 份草稿、{counts.Versions} 个版本、{counts.Projects} 个项目、" +
                $"{counts.Relations} 条演化关系、{counts.CandidateDecisions} 条裁决、{counts.PdfSnapshots} 份 PDF 快照。" +
                "正在重建本机索引……";
            // 导入会替换库文件：重新打开工作区。
            await ReopenWorkspaceAsync();
            await BootstrapSemanticAsync();
            MigrationMessage += "完成。";
        }
        catch (Exception ex)
        {
            MigrationMessage = $"导入失败：{ex.Message}（未做任何写入，请检查档案后重试）";
            await ReopenWorkspaceAsync();
        }
        finally
        {
            MigrationRunning = false;
        }
    }

    private async Task ReopenWorkspaceAsync()
    {
        var (dbPath, snapshots) = AppDatabase.DefaultWorkspace();
        await ReopenAsync(dbPath, snapshots);
    }

    public async Task ReopenAsync(string dbPath, string snapshots)
    {
        if (_database is not null)
        {
            try { await _database.DisposeAsync(); } catch { }
        }
        _database = new AppDatabase(dbPath, snapshots);
        _importer = new LocalFileImporter(_database, snapshots);
        _webImporter = new WebImporter(_database);
        _gitHubImporter = new GitHubImporter(_database, snapshots);
        _candidateEngine = null;
        BootstrapError = null;
        WorkspacePath = Path.GetDirectoryName(dbPath)!;
        await ReloadAsync();
        OnPropertyChanged(nameof(CanImportFromMac));
    }
}

/// <summary>远程分析开关持久化（对齐 Mac UserDefaults bool）。</summary>
public static class RemoteEnabledStore
{
    private const string FileName = "remote-analysis-enabled";

    public static bool Load()
    {
        var path = StorePath();
        return File.Exists(path);
    }

    public static void Save(bool enabled)
    {
        var path = StorePath();
        if (enabled)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "1");
        }
        else if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private static string StorePath()
    {
        var (dbPath, _) = AppDatabase.DefaultWorkspace();
        return Path.Combine(Path.GetDirectoryName(dbPath)!, FileName);
    }
}
