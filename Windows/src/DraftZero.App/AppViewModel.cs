using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DraftZero.App.Services;
using DraftZero.Core;
using System.Collections.ObjectModel;

namespace DraftZero.App;

/// <summary>
/// 主视图模型：Mac AppModel 的 Avalonia 移植（W-001~W-009 全部入口与状态）。
/// 数据层 DraftZero.Core；平台服务（Key 存储、PDF 渲染、对话框）经接口注入。
/// </summary>
public partial class AppViewModel : ObservableObject
{
    private readonly ISecretStore _secretStore;
    private AppDatabase? _database;
    private LocalFileImporter? _importer;
    private WebImporter? _webImporter;
    private GitHubImporter? _gitHubImporter;
    private AutoVersioner? _versioner;
    private CandidateEngine? _candidateEngine;
    private ITextEmbedding? _embedder;

    public ISecretStore SecretStore => _secretStore;

    // ---- 发布状态（对应 Mac @Published） ----

    public ObservableCollection<Draft> Drafts { get; } = [];
    public ObservableCollection<Project> Projects { get; } = [];
    public Dictionary<Guid, int> ProjectCounts { get; private set; } = [];
    public Dictionary<Guid, List<string>> DraftProjectNames { get; private set; } = [];
    public Dictionary<Guid, DateTime> LastEdited { get; private set; } = [];
    public Dictionary<Guid, List<Tag>> ProjectTags { get; private set; } = [];
    public Dictionary<Guid, List<Draft>> ProjectMembers { get; private set; } = [];

    [ObservableProperty] private SidebarItem _sidebarSelection = SidebarItem.DraftBox;
    [ObservableProperty] private DraftBoxFilter _draftBoxFilter = DraftBoxFilter.All;
    [ObservableProperty] private Guid? _selectedDraftId;
    [ObservableProperty] private Project? _selectedProject;
    [ObservableProperty] private Guid? _selectedCluePairId;
    [ObservableProperty] private bool _showNewDraftPage;
    [ObservableProperty] private bool _showAddLinkSheet;
    [ObservableProperty] private bool _showQuickSearch;
    [ObservableProperty] private bool _showImportFromMac;
    [ObservableProperty] private string? _bootstrapError;
    [ObservableProperty] private string? _newDraftError;
    [ObservableProperty] private string? _linkError;
    [ObservableProperty] private bool _linkLoading;

    // 语义线索（R-004）
    [ObservableProperty] private CandidateReport? _clueReport;
    [ObservableProperty] private SemanticUiState _semanticState = SemanticUiState.Idle;
    [ObservableProperty] private string? _semanticStateDetail;
    public ObservableCollection<CandidatePair> LeadPairs { get; } = [];
    public ObservableCollection<CandidatePair> DuplicatePairs { get; } = [];
    public ObservableCollection<CandidatePair> DeferredLeads { get; } = [];
    public ObservableCollection<CandidatePair> RejectedLeads { get; } = [];
    public ObservableCollection<RemoteSuggestion> RemoteSuggestions { get; } = [];

    // 导入批次（R-001 逐项报告）
    public ObservableCollection<ImportItemRow> ImportItems { get; } = [];
    [ObservableProperty] private bool _importSessionRunning;

    // 仓库浏览（R-002）
    [ObservableProperty] private RepoBrowseState? _repoBrowse;

    // 编辑状态（UI-07）
    [ObservableProperty] private EditSaveStateKind _editSaveState = EditSaveStateKind.Idle;

    // 远程分析（R-010）
    [ObservableProperty] private bool _remoteEnabled;
    [ObservableProperty] private bool _remoteHasKey;
    [ObservableProperty] private string? _remoteStatus;
    [ObservableProperty] private bool _remoteAnalyzing;
    private DeepSeekProvider? _remoteProvider;

    // 深链待确认（W-009：写入型必须应用内确认）
    [ObservableProperty] private PendingDeepLinkWrite? _pendingDeepLinkWrite;

    // 迁移导入（W-011）
    [ObservableProperty] private string? _migrationMessage;
    [ObservableProperty] private bool _migrationRunning;

    public string? WorkspaceOverrideDirectory { get; }
    public string WorkspacePath { get; private set; } = "";

    public event Action? RequestCloseNewDraft;

    public AppViewModel(ISecretStore secretStore)
    {
        _secretStore = secretStore;
        WorkspaceOverrideDirectory = Environment.GetEnvironmentVariable("DZ_WORKSPACE_DIR");
    }

    public enum SemanticUiState { Idle, Indexing, Ready, Degraded }

    public enum EditSaveStateKind { Idle, Saving, Saved, Failed }

    public Draft? SelectedDraft => SelectedDraftId is { } id ? Drafts.FirstOrDefault(d => d.Id == id) : null;

    public int PendingClueCount => LeadPairs.Count + DuplicatePairs.Count + RemoteSuggestions.Count;

    public int UngroupedCount => Drafts.Count(d => (ProjectCounts.GetValueOrDefault(d.Id)) == 0);

    /// <summary>Mac 档案导入只允许空工作区（以已加载的四类数据判断，与
    /// WorkspaceImporter 的空库判定同口径，避免在 UI 属性里同步查库）。</summary>
    public bool CanImportFromMac =>
        _database is not null && Drafts.Count == 0 && Projects.Count == 0
            && LeadPairs.Count == 0 && DuplicatePairs.Count == 0 && RemoteSuggestions.Count == 0;

    // ---- 启动 ----

    public async Task BootstrapAsync()
    {
        if (_database is not null) return;
        try
        {
            var (dbPath, snapshots) = AppDatabase.DefaultWorkspace();
            WorkspacePath = Path.GetDirectoryName(dbPath)!;
            _database = new AppDatabase(dbPath, snapshots);
            _importer = new LocalFileImporter(_database, snapshots);
            _webImporter = new WebImporter(_database);
            _gitHubImporter = new GitHubImporter(_database, snapshots);
            _versioner = new AutoVersioner(async (draftId, content) =>
            {
                await _database.RecordVersionIfChangedAsync(draftId, content, VersionOrigin.AutoSave);
            });
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            BootstrapError = $"无法打开本机工作区：{ex.Message}";
        }
    }

    public async Task ReloadAsync()
    {
        if (_database is null) return;
        var drafts = await _database.DraftsAsync();
        Drafts.Clear();
        foreach (var d in drafts) Drafts.Add(d);
        ProjectCounts = await _database.ProjectCountsByDraftAsync();
        LastEdited = await _database.LastEditedByDraftAsync();
        var projects = await _database.ProjectsAsync();
        Projects.Clear();
        foreach (var p in projects) Projects.Add(p);
        if (SelectedProject is { } selected)
        {
            SelectedProject = Projects.FirstOrDefault(p => p.Id == selected.Id);
        }
        await ReloadProjectDetailsAsync();
        await ReloadDraftProjectNamesAsync();
        // 通知缓存页面自刷新（列表页只建一次，靠这些信号更新内容）
        OnPropertyChanged(nameof(Drafts));
        OnPropertyChanged(nameof(ProjectCounts));
        OnPropertyChanged(nameof(Projects));
        OnPropertyChanged(nameof(UngroupedCount));
        OnPropertyChanged(nameof(WorkspacePath));
        OnPropertyChanged(nameof(CanImportFromMac));
    }

    private async Task ReloadDraftProjectNamesAsync()
    {
        if (_database is null) return;
        var names = new Dictionary<Guid, List<string>>();
        foreach (var draft in Drafts)
        {
            var owning = await _database.ProjectsContainingAsync(draft.Id);
            names[draft.Id] = owning.Select(p => p.Name).ToList();
        }
        DraftProjectNames = names;
        OnPropertyChanged(nameof(DraftProjectNames));
    }

    public async Task ReloadProjectDetailsAsync()
    {
        if (_database is null) return;
        var tags = new Dictionary<Guid, List<Tag>>();
        var members = new Dictionary<Guid, List<Draft>>();
        foreach (var project in Projects)
        {
            tags[project.Id] = await _database.TagsOnProjectAsync(project.Id);
            members[project.Id] = await _database.DraftsInProjectAsync(project.Id);
        }
        ProjectTags = tags;
        ProjectMembers = members;
        OnPropertyChanged(nameof(ProjectTags));
        OnPropertyChanged(nameof(ProjectMembers));
    }

    public void SelectProject(Project project)
    {
        SelectedProject = project;
        SelectedDraftId = null;
        ShowNewDraftPage = false;
        SidebarSelection = project.Status == ProjectStatus.Archived ? SidebarItem.Archived : SidebarItem.Projects;
    }

    public void OpenDraft(Draft draft)
    {
        SelectedProject = null;
        ShowNewDraftPage = false;
        SelectedDraftId = draft.Id;
    }

    public void CloseDetailPages()
    {
        ShowNewDraftPage = false;
        SelectedDraftId = null;
        SelectedProject = null;
    }

    // ---- 本地文件导入（R-001 / W-001） ----

    public async Task ImportFilesAsync(IReadOnlyList<string> paths)
    {
        if (_importer is null || paths.Count == 0) return;
        var before = Drafts.Select(d => d.Id).ToHashSet();
        await RunBatchAsync(
            paths.Select(Path.GetFileName).ToList(),
            paths.Select<string, ImportItemRow.ItemSource?>(p => new ImportItemRow.LocalFileSource(p)).ToList(),
            async index => ImportItemRow.ToStatus(
                await _importer.ImportFileAsync(paths[index])));
        await AnalyzeNewDraftsSinceAsync(before);
    }

    public async Task ImportAnywayAsync(Guid itemId)
    {
        if (_importer is null) return;
        var item = ImportItems.FirstOrDefault(i => i.Id == itemId);
        if (item?.Source is not ImportItemRow.LocalFileSource local) return;
        item.Status = ImportItemRow.ImportItemStatus.Running;
        item.Status = ImportItemRow.ToStatus(
            await _importer.ImportFileAsync(local.Path, allowDuplicate: true));
        await ReloadAsync();
    }

    // ---- 链接导入：网页与 GitHub（R-002 / W-002） ----

    public async Task OpenLinkAsync(string raw)
    {
        if (_webImporter is null || _gitHubImporter is null) return;
        LinkError = null;
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return;
        var before = Drafts.Select(d => d.Id).ToHashSet();

        if (GitHubLinkParser.Parse(trimmed) is { } refSpec)
        {
            if (refSpec.Kind == GitHubLinkParser.LinkKind.Repo)
            {
                await OpenRepoAsync(refSpec);
            }
            else
            {
                var name = refSpec.Path ?? "GitHub 文件";
                LinkLoading = true;
                try
                {
                    await RunBatchAsync([name], [null], async _ => ImportItemRow.ToStatus(
                        await _gitHubImporter.ImportSingleFileAsync(refSpec)));
                    ShowAddLinkSheet = false;
                    await AnalyzeNewDraftsSinceAsync(before);
                }
                finally
                {
                    LinkLoading = false;
                }
            }
            return;
        }

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url)
            || url.Scheme is not ("http" or "https"))
        {
            LinkError = "无法识别链接：请使用 http(s) 网页或 github.com 链接";
            return;
        }
        LinkLoading = true;
        try
        {
            await RunBatchAsync([url.Host], [null], async _ => ImportItemRow.ToStatus(
                await _webImporter.ImportWebPageAsync(url)));
            ShowAddLinkSheet = false;
            await AnalyzeNewDraftsSinceAsync(before);
        }
        finally
        {
            LinkLoading = false;
        }
    }

    private async Task OpenRepoAsync(GitHubLinkParser.Ref refSpec)
    {
        if (_gitHubImporter is null) return;
        LinkLoading = true;
        try
        {
            var branch = refSpec.RefName
                ?? await _gitHubImporter.Client.DefaultBranchAsync(refSpec.Owner, refSpec.Repo);
            var (treeSha, entries, truncated) = await _gitHubImporter.Client
                .ListTreeAsync(refSpec.Owner, refSpec.Repo, branch);
            var blobs = entries.Where(e => e.Type == "blob").ToList();
            if (refSpec.Path is { } prefix)
            {
                blobs = blobs.Where(e => e.Path == prefix || e.Path.StartsWith(prefix + "/")).ToList();
            }
            blobs.Sort((a, b) => string.CompareOrdinal(a.Path, b.Path));
            RepoBrowse = new RepoBrowseState
            {
                Owner = refSpec.Owner,
                Repo = refSpec.Repo,
                Branch = branch,
                TreeSha = treeSha,
                Entries = blobs.Select(e => new RepoEntryRow
                {
                    Path = e.Path,
                    Size = e.Size ?? 0,
                    BlobSha = e.Sha,
                    IsSupported = LocalFileImporter.SupportedExtensions.Contains(
                        Path.GetExtension(e.Path).TrimStart('.').ToLowerInvariant()),
                    IsTooLarge = (e.Size ?? 0) > GitHubImporter.MaxTextFileSize,
                }).ToList(),
                Truncated = truncated,
            };
        }
        catch (Exception ex)
        {
            LinkError = ex.Message;
        }
        finally
        {
            LinkLoading = false;
        }
    }

    /// <summary>导入勾选的仓库文件；取消勾选即不导入任何内容（R-002）。</summary>
    public async Task ImportCheckedRepoFilesAsync()
    {
        if (_gitHubImporter is null || RepoBrowse is null) return;
        var browse = RepoBrowse;
        var checkedEntries = browse.Entries.Where(e => browse.Checked.Contains(e.Path)).ToList();
        if (checkedEntries.Count == 0) return;
        var requests = checkedEntries.Select(e => new GitHubImportRequest
        {
            Owner = browse.Owner, Repo = browse.Repo, Branch = browse.Branch,
            TreeSha = browse.TreeSha, Path = e.Path, BlobSha = e.BlobSha,
        }).ToList();
        var before = Drafts.Select(d => d.Id).ToHashSet();
        ShowAddLinkSheet = false;
        RepoBrowse = null;
        await RunBatchAsync(
            requests.Select(r => r.Path).ToList(),
            requests.Select<GitHubImportRequest, ImportItemRow.ItemSource?>(
                r => new ImportItemRow.GitHubFileSource(r)).ToList(),
            async index => ImportItemRow.ToStatus(
                await _gitHubImporter.ImportFileAsync(requests[index])));
        await AnalyzeNewDraftsSinceAsync(before);
    }

    private async Task RunBatchAsync(
        IReadOnlyList<string?> names,
        IReadOnlyList<ImportItemRow.ItemSource?> sources,
        Func<int, Task<ImportItemRow.ImportItemStatus>> perform)
    {
        if (names.Count == 0) return;
        ImportItems.Clear();
        for (int i = 0; i < names.Count; i++)
        {
            ImportItems.Add(new ImportItemRow
            {
                Id = Guid.NewGuid(),
                DisplayName = names[i] ?? "",
                Source = sources[i],
            });
        }
        ImportSessionRunning = true;
        for (int i = 0; i < ImportItems.Count; i++)
        {
            ImportItems[i].Status = ImportItemRow.ImportItemStatus.Running;
            var status = await perform(i);
            ImportItems[i].Status = status;
            ImportSessionRunning = i < ImportItems.Count - 1;
            await ReloadAsync();
        }
        ImportSessionRunning = false;
    }

    // ---- 新建草稿（R-001 / UI-04） ----

    public void OpenNewDraftPage()
    {
        ShowNewDraftPage = true;
        SelectedDraftId = null;
        SelectedProject = null;
        NewDraftError = null;
    }

    public static string FallbackTitle(string content)
    {
        var firstLine = content.Split('\n')
            .Select(l => l.Trim())
            .FirstOrDefault(l => l.Length > 0) ?? "";
        return firstLine.Length == 0 ? "" : firstLine.Length <= 24 ? firstLine : firstLine[..24];
    }

    public async Task<bool> CreateDraftAsync(string title, string content)
    {
        if (_database is null)
        {
            NewDraftError = "工作区尚未就绪，请稍后重试";
            return false;
        }
        var effectiveTitle = string.IsNullOrWhiteSpace(title) ? FallbackTitle(content) : title;
        var before = Drafts.Select(d => d.Id).ToHashSet();
        try
        {
            var draft = await _database.CreateManualDraftAsync(effectiveTitle, content);
            await ReloadAsync();
            SelectedDraftId = draft.Id;
            ShowNewDraftPage = false;
            await AnalyzeNewDraftsSinceAsync(before);
            NewDraftError = null;
            return true;
        }
        catch (Exception ex)
        {
            NewDraftError = $"保存失败：{ex.Message}";
            return false;
        }
    }

    // ---- 编辑与版本（R-003/R-006 / W-006） ----

    /// <summary>编辑保存失败的具体原因（不挪用语义状态字段）。</summary>
    [ObservableProperty] private string? _editSaveError;

    public async Task SaveEditAsync(Guid draftId, string text)
    {
        if (_database is null) return;
        EditSaveState = EditSaveStateKind.Saving;
        try
        {
            await _database.UpdateDraftContentAsync(draftId, text);
            _versioner?.ContentChanged(draftId, text);
            if (SelectedDraft is { } selected && selected.Id == draftId)
            {
                selected.Content = text;
            }
            EditSaveState = EditSaveStateKind.Saved;
            EditSaveError = null;
        }
        catch (Exception ex)
        {
            EditSaveState = EditSaveStateKind.Failed;
            EditSaveError = ex.Message;
        }
    }

    public Task FlushVersionAsync(Guid draftId) => _versioner?.FlushAsync(draftId) ?? Task.CompletedTask;
    public Task FlushAllVersionsAsync() => _versioner?.FlushAllAsync() ?? Task.CompletedTask;

    public async Task RestoreVersionAsync(DraftVersion version)
    {
        if (_database is null) return;
        await _database.RestoreVersionAsync(version.Id);
        await ReloadAsync();
    }

    // ---- 只读快照衍生（R-003 / W-003） ----

    public async Task CreateEditableCopyAsync(Draft draft)
    {
        if (_database is null || draft.Content is null) return;
        var derived = await _database.CreateDerivedDraftAsync(draft.Id, draft.Title + "（可编辑）", draft.Content);
        await ReloadAsync();
        if (derived is not null) SelectedDraftId = derived.Id;
    }

    // ---- 删除（R-011 / W-009） ----

    public async Task<string> DeletionImpactAsync(Draft draft)
    {
        if (_database is null) return "";
        var lines = new List<string>();
        var projects = await _database.ProjectsContainingAsync(draft.Id);
        lines.Add(projects.Count == 0
            ? "不属于任何项目。"
            : "所属项目：" + string.Join("、", projects.Select(p => p.Name)));
        var versionCount = (await _database.VersionsAsync(draft.Id)).Count;
        lines.Add($"将删除正文与 {versionCount} 个版本，相关关系将显示为「来源已删除」。");
        if (draft.SnapshotFileURL is not null)
        {
            lines.Add("应用内的 PDF 快照也会一并删除（原文件与远端内容不受影响）。");
        }
        return string.Join("\n", lines);
    }

    public async Task DeleteDraftAsync(Draft draft)
    {
        if (_database is null) return;
        await _database.DeleteDraftAsync(draft.Id);
        if (draft.SnapshotFileURL is not null)
        {
            try { File.Delete(draft.SnapshotFileURL); } catch { }
        }
        if (SelectedDraftId == draft.Id) SelectedDraftId = null;
        await ReloadAsync();
    }

    // ---- 项目（R-005/R-008 / W-005） ----

    public async Task CreateProjectAsync(string name)
    {
        if (_database is null) return;
        await _database.CreateProjectAsync(name);
        await ReloadAsync();
    }

    /// <summary>创建并返回新项目（归入项目浮层用）。</summary>
    public async Task<Project> CreateProjectAsyncWithReturn(string name)
    {
        if (_database is null)
        {
            throw new InvalidOperationException("工作区尚未就绪");
        }
        var project = await _database.CreateProjectAsync(name);
        await ReloadAsync();
        return project;
    }

    public async Task RenameProjectAsync(Project project, string name)
    {
        if (_database is null) return;
        await _database.RenameProjectAsync(project.Id, name);
        await ReloadAsync();
    }

    public async Task SetProjectStatusAsync(Project project, ProjectStatus status)
    {
        if (_database is null) return;
        await _database.SetProjectStatusAsync(project.Id, status);
        await ReloadAsync();
    }

    public async Task DeleteProjectAsync(Project project)
    {
        if (_database is null) return;
        await _database.DeleteProjectAsync(project.Id);
        if (SelectedProject?.Id == project.Id) SelectedProject = null;
        await ReloadAsync();
    }

    public async Task AddDraftToProjectAsync(Guid draftId, Guid projectId)
    {
        if (_database is null) return;
        await _database.AddDraftToProjectAsync(draftId, projectId);
        await ReloadAsync();
    }

    public async Task RemoveDraftFromProjectAsync(Guid draftId, Guid projectId)
    {
        if (_database is null) return;
        await _database.RemoveDraftFromProjectAsync(draftId, projectId);
        await ReloadAsync();
    }

    public async Task AddTagAsync(string name, Guid projectId)
    {
        if (_database is null) return;
        await _database.AddTagToProjectAsync(name, projectId);
        await ReloadAsync();
    }

    public async Task RemoveTagAsync(string name, Guid projectId)
    {
        if (_database is null) return;
        await _database.RemoveTagFromProjectAsync(name, projectId);
        await ReloadAsync();
    }

    // ---- 拆分 / 合并（R-007 / W-006） ----

    public async Task SplitDraftAsync(Draft draft, string piece, int offset)
    {
        if (_database is null) return;
        var split = await _database.SplitDraftAsync(draft.Id, piece, offset, null);
        await ReloadAsync();
        if (split is not null) SelectedDraftId = split.Id;
    }

    public async Task MergeDraftsAsync(IReadOnlyList<Guid> ids, string? title)
    {
        if (_database is null) return;
        var merged = await _database.MergeDraftsAsync(ids, title);
        await ReloadAsync();
        if (merged is not null) SelectedDraftId = merged.Id;
    }

    public async Task<List<Project>> DatabaseProjectsContaining(Guid draftId)
    {
        if (_database is null) return [];
        return await _database.ProjectsContainingAsync(draftId);
    }

    public async Task<List<DraftVersion>> DatabaseVersions(Guid draftId)
    {
        if (_database is null) return [];
        return await _database.VersionsAsync(draftId);
    }

    /// <summary>全文搜索草稿（FTS5 trigram 索引；标题+正文子串，含 2 字中文）。</summary>
    public async Task<List<Draft>> DatabaseSearchDraftsAsync(string query)
    {
        if (_database is null) return [];
        var ids = await _database.SearchDraftsAsync(query);
        return ids.Select(id => Drafts.FirstOrDefault(d => d.Id == id))
            .Where(d => d is not null).Cast<Draft>().ToList();
    }

    public async Task<List<EvolutionRelation>> LoadRelationsAsync(Guid draftId)
    {
        if (_database is null) return [];
        return await _database.RelationsAsync(draftId);
    }

    /// <summary>项目演化：成员相关的全部关系（含"来源已删除"的保留行）。</summary>
    public async Task<List<EvolutionRelation>> LoadRelationsForMembersAsync(IReadOnlyCollection<Guid> memberIds)
    {
        if (_database is null) return [];
        var all = new Dictionary<Guid, EvolutionRelation>();
        foreach (var id in memberIds)
        {
            foreach (var relation in await _database.RelationsAsync(id))
            {
                all[relation.Id] = relation;
            }
        }
        return all.Values.OrderByDescending(r => r.CreatedAt).ToList();
    }

    public async Task UpdateRelationNoteAsync(Guid relationId, string? note, Guid draftId)
    {
        if (_database is null) return;
        await _database.UpdateRelationNoteAsync(relationId, note);
    }

    public string? DraftTitle(Guid id) => Drafts.FirstOrDefault(d => d.Id == id)?.Title;
}
