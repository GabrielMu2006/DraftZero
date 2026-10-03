using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using DraftZero.App.Services;
using DraftZero.App.Views;
using DraftZero.Core;
using System.Collections.ObjectModel;

namespace DraftZero.App;

/// <summary>
/// 主窗口：索引脊背 + 主区页面路由（UI-02）。快捷键 Ctrl+N/O/L/K、Ctrl+1…6；
/// 草稿箱与线索台支持文件拖放（R-001）。
/// </summary>
public partial class MainWindow : Window
{
    public AppViewModel Model { get; }
    public IPdfPageRenderer PdfRenderer { get; }

    private readonly List<(SidebarItem Item, Border Host, TextBlock Badge)> _navItems = [];

    /// <summary>
    /// 列表页缓存（UI-02：返回列表保留筛选与滚动位置）。详情页/新稿页是瞬态的，
    /// 每次打开重建；列表页每侧栏项只建一次，由页面自身订阅数据变化刷新。
    /// </summary>
    private readonly Dictionary<SidebarItem, Control> _listPageCache = new();

    public MainWindow()
    {
        InitializeComponent();
        Model = null!;
        PdfRenderer = null!;
    }

    public MainWindow(AppViewModel model, IPdfPageRenderer pdfRenderer)
    {
        InitializeComponent();
        Model = model;
        PdfRenderer = pdfRenderer;
        // F-005：浮层内 XAML 绑定依赖 DataContext（缺省为 null → 导入结果列表空白）
        DataContext = model;
        TryLoadWindowPlacement();
        BuildNavList();
        // F-002：AllowDrop 挂在窗口根（axaml）；DragOver 必须声明效果，否则系统按 None 处理丢不进来
        AddHandler(DragDrop.DragOverEvent, OnDragOver);
        AddHandler(DragDrop.DropEvent, OnDrop);
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppViewModel.SidebarSelection) or nameof(AppViewModel.SelectedDraftId)
                or nameof(AppViewModel.SelectedProject) or nameof(AppViewModel.ShowNewDraftPage))
            {
                RenderPage();
            }
            if (e.PropertyName is nameof(AppViewModel.LeadPairs) or nameof(AppViewModel.DuplicatePairs)
                or nameof(AppViewModel.RemoteSuggestions) or nameof(AppViewModel.UngroupedCount))
            {
                UpdateBadges();
            }
        };
        model.ImportItems.CollectionChanged += (_, _) =>
        {
            if (model.ImportItems.Count > 0) ImportOverlay.IsVisible = true;
        };
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.PendingDeepLinkWrite))
            {
                DeepLinkConfirmSheet.Show(model.PendingDeepLinkWrite);
            }
            if (e.PropertyName == nameof(AppViewModel.RepoBrowse))
            {
                if (model.RepoBrowse is { } browse) RepoBrowseSheet.Show(browse, Model);
                else RepoBrowseSheet.IsVisible = false;
            }
        };
        Closing += async (_, _) =>
        {
            await Model.FlushAllVersionsAsync();
            SaveWindowPlacement();
        };
        RenderPage();
        UpdateBadges();
    }

    // ---- 窗口图标与位置记忆（标题栏/任务栏不再显示默认图标；重开恢复上次位置） ----

    private void TryLoadWindowPlacement()
    {
        try
        {
            using var stream = Avalonia.Platform.AssetLoader.Open(
                new Uri("avares://DraftZero/Assets/DraftZero.ico"));
            Icon = new WindowIcon(stream);
        }
        catch { /* 图标缺失不阻塞启动 */ }

        try
        {
            var (dbPath, _) = AppDatabase.DefaultWorkspace();
            var file = Path.Combine(Path.GetDirectoryName(dbPath)!, "window-placement.json");
            if (!File.Exists(file)) return;
            var p = System.Text.Json.JsonSerializer.Deserialize<WindowPlacement>(File.ReadAllText(file));
            if (p is null) return;
            if (p.Width >= MinWidth && p.Height >= MinHeight)
            {
                Width = p.Width;
                Height = p.Height;
            }
            if (p.X is int x && p.Y is int y)
            {
                var virtualScreen = Screens.All;
                var visible = virtualScreen.Any(s =>
                    x > s.Bounds.X - 200 && x < s.Bounds.Right && y > s.Bounds.Y - 50 && y < s.Bounds.Bottom);
                if (visible)
                {
                    Position = new PixelPoint(x, y);
                }
            }
        }
        catch { /* 位置文件损坏则用默认值 */ }
    }

    private void SaveWindowPlacement()
    {
        try
        {
            var (dbPath, _) = AppDatabase.DefaultWorkspace();
            var file = Path.Combine(Path.GetDirectoryName(dbPath)!, "window-placement.json");
            var placement = new WindowPlacement
            {
                X = Position.X,
                Y = Position.Y,
                Width = (int)Width,
                Height = (int)Height,
            };
            File.WriteAllText(file, System.Text.Json.JsonSerializer.Serialize(placement));
        }
        catch { /* 保存失败不影响退出 */ }
    }

    private sealed class WindowPlacement
    {
        public int X { get; set; }
        public int Y { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
    }

    private void BuildNavList()
    {
        NavList.Children.Clear();
        _navItems.Clear();
        var items = new[]
        {
            (SidebarItem.DraftBox, "01", "草稿箱"),
            (SidebarItem.ClueDesk, "02", "线索台"),
            (SidebarItem.Projects, "03", "想法项目"),
            (SidebarItem.Todo, "04", "TODO"),
            (SidebarItem.Archived, "05", "暂时封存"),
        };
        foreach (var (item, number, name) in items)
        {
            var badge = new TextBlock
            {
                FontSize = 11,
                Foreground = Brushes.Transparent,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 2, 0),
            };
            var host = new Border
            {
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 7),
                Child = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        new TextBlock { Text = number, FontSize = 12, Foreground = ArchiveUI.Accent },
                        new TextBlock { Text = name, FontSize = 13.5, Foreground = ArchiveUI.TextBrush },
                        badge,
                    },
                },
            };
            host.Tapped += async (_, _) =>
            {
                // 导航点击 = 离开当前详情/新稿（UI-02：返回入口与侧栏同效），列表缓存保留滚动
                await LeaveDetailAsync();
                Model.SidebarSelection = item;
            };
            NavList.Children.Add(host);
            _navItems.Add((item, host, badge));
        }
        // 项目书签（最多 3 个）
        var bookmarks = Model.Projects
            .Where(p => p.Status != ProjectStatus.Archived)
            .OrderByDescending(p => p.CreatedAt)
            .Take(3);
        if (bookmarks.Any())
        {
            NavList.Children.Add(new TextBlock
            {
                Text = "项目书签",
                FontSize = 11,
                Foreground = ArchiveUI.MutedText,
                Margin = new Thickness(10, 10, 0, 4),
            });
            foreach (var project in bookmarks)
            {
                var host = new Border
                {
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(10, 5),
                    Child = new TextBlock
                    {
                        Text = "· " + project.Name,
                        FontSize = 12.5,
                        Foreground = ArchiveUI.TextBrush,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                };
                var captured = project;
                host.Tapped += (_, _) => Model.SelectProject(captured);
                ToolTip.SetTip(host, project.Name);
                NavList.Children.Add(host);
            }
        }
        NavSettings.Tapped += async (_, _) =>
        {
            await LeaveDetailAsync();
            Model.SidebarSelection = SidebarItem.Settings;
        };
    }

    /// <summary>离开详情/新稿前结算挂起的版本（与详情页返回按钮同语义）。</summary>
    private async Task LeaveDetailAsync()
    {
        if (Model.SelectedDraft is { IsEditable: true } editing)
        {
            await Model.FlushVersionAsync(editing.Id);
        }
        if (Model.ShowNewDraftPage || Model.SelectedDraftId is not null || Model.SelectedProject is not null)
        {
            Model.ShowNewDraftPage = false;
            Model.SelectedDraftId = null;
            Model.SelectedProject = null;
        }
    }

    private void UpdateBadges()
    {
        foreach (var (item, _, badge) in _navItems)
        {
            var count = item switch
            {
                SidebarItem.ClueDesk => Model.PendingClueCount,
                SidebarItem.DraftBox => Model.UngroupedCount,
                SidebarItem.Projects => Model.Projects.Count,
                _ => 0,
            };
            badge.Text = count > 0 ? count.ToString() : "";
            badge.Foreground = count > 0 ? ArchiveUI.Accent : Brushes.Transparent;
        }
    }

    /// <summary>主区路由：详情与新稿占用主区完整页面（UI-02）；列表页走缓存保留滚动。</summary>
    private void RenderPage()
    {
        foreach (var (item, host, _) in _navItems)
        {
            host.Background = Model.SidebarSelection == item
                ? ArchiveUI.Selected
                : Brushes.Transparent;
        }
        NavSettings.Background = Model.SidebarSelection == SidebarItem.Settings
            ? ArchiveUI.Selected
            : Brushes.Transparent;

        Control page;
        if (Model.ShowNewDraftPage)
        {
            page = new NewDraftPage(Model);
        }
        else if (Model.SelectedDraft is { } draft)
        {
            page = new DraftDetailPage(Model, draft, PdfRenderer);
        }
        else if (Model.SelectedProject is { } project)
        {
            page = new ProjectDetailPage(Model, project);
        }
        else
        {
            page = GetOrBuildListPage(Model.SidebarSelection);
        }
        PageHost.Content = page;
        UpdateBadges();
    }

    private Control GetOrBuildListPage(SidebarItem item)
    {
        if (_listPageCache.TryGetValue(item, out var cached)) return cached;
        Control page = item switch
        {
            SidebarItem.ClueDesk => new ClueDeskPage(Model),
            SidebarItem.Projects => new ProjectsPage(Model, null),
            SidebarItem.Todo => new ProjectsPage(Model, ProjectStatus.Todo),
            SidebarItem.Archived => new ProjectsPage(Model, ProjectStatus.Archived),
            SidebarItem.Settings => new SettingsPage(Model),
            _ => new DraftBoxPage(Model),
        };
        _listPageCache[item] = page;
        return page;
    }

    // ---- 快捷键（W-010：Ctrl 系列） ----

    protected override async void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        if (!ctrl) return;
        switch (e.Key)
        {
            case Key.N:
                Model.OpenNewDraftPage();
                e.Handled = true;
                break;
            case Key.O:
                await PickAndImportAsync();
                e.Handled = true;
                break;
            case Key.L:
                Model.ShowAddLinkSheet = true;
                AddLinkSheet.Show(Model);
                e.Handled = true;
                break;
            case Key.K:
                QuickSearchSheet.Show(Model);
                e.Handled = true;
                break;
            case Key.D1: Model.SidebarSelection = SidebarItem.DraftBox; e.Handled = true; break;
            case Key.D2: Model.SidebarSelection = SidebarItem.ClueDesk; e.Handled = true; break;
            case Key.D3: Model.SidebarSelection = SidebarItem.Projects; e.Handled = true; break;
            case Key.D4: Model.SidebarSelection = SidebarItem.Todo; e.Handled = true; break;
            case Key.D5: Model.SidebarSelection = SidebarItem.Archived; e.Handled = true; break;
            case Key.D6: Model.SidebarSelection = SidebarItem.Settings; e.Handled = true; break;
        }
    }

    // ---- 文件选择（⌘O 对应 Ctrl+O） ----

    public async Task PickAndImportAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "选择要收纳的 TXT、Markdown 或 PDF 文件",
            AllowMultiple = true,
            FileTypeFilter =
            [
                new FilePickerFileType("文本与 PDF")
                {
                    Patterns = ["*.txt", "*.md", "*.markdown", "*.text", "*.pdf"],
                },
            ],
        });
        var paths = files.Select(f => f.Path.LocalPath).ToList();
        if (paths.Count > 0)
        {
            await Model.ImportFilesAsync(paths);
        }
    }

    // ---- 拖放（R-001 / W-001） ----

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        if (Model.ShowNewDraftPage || Model.SelectedDraft is not null)
        {
            e.DragEffects = DragDropEffects.None;
            return;
        }
        e.DragEffects = DragDropEffects.Copy;
    }

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        if (Model.ShowNewDraftPage || Model.SelectedDraft is not null) return;
        var files = (e.DataTransfer.TryGetFiles() ?? []).ToList();
        if (files.Count == 0) return;
        var paths = files
            .Select(f => f.Path.LocalPath)
            .Where(p => LocalFileImporter.SupportedExtensions.Contains(
                Path.GetExtension(p).TrimStart('.').ToLowerInvariant()))
            .ToList();
        var unsupported = files.Count - paths.Count;
        if (paths.Count > 0)
        {
            await Model.ImportFilesAsync(paths);
        }
        if (unsupported > 0)
        {
            // 单独反馈不受支持的文件（逐项报告原则）
            Model.ImportItems.Add(new ImportItemRow
            {
                Id = Guid.NewGuid(),
                DisplayName = $"{unsupported} 个不受支持的文件",
                Source = null,
                Status = ImportItemRow.ImportItemStatus.Failed,
                FailureReason = "仅支持 TXT / Markdown / PDF",
            });
            ImportOverlay.IsVisible = true;
        }
    }

    private void OnImportAnyway(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Guid id } )
        {
            _ = Model.ImportAnywayAsync(id);
        }
    }

    private void OnCloseImportOverlay(object? sender, RoutedEventArgs e) =>
        ImportOverlay.IsVisible = false;

    // ---- 全局顶栏（F-006：新草稿/搜索可见按钮） ----

    private void OnTopNewDraft(object? sender, RoutedEventArgs e)
    {
        Model.SelectedDraftId = null;
        Model.SelectedProject = null;
        Model.OpenNewDraftPage();
    }

    private void OnTopSearch(object? sender, RoutedEventArgs e) =>
        QuickSearchSheet.Show(Model);
}
