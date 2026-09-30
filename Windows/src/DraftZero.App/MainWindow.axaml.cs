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
    private TextBlock? _pendingBadge;

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
        BuildNavList();
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
        Closing += async (_, _) => await Model.FlushAllVersionsAsync();
        RenderPage();
        UpdateBadges();
    }

    private void BuildNavList()
    {
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
                        new TextBlock { Text = number, FontSize = 12, Foreground = (IBrush)Resources["AccentBrush"]! },
                        new TextBlock { Text = name, FontSize = 13.5, Foreground = (IBrush)Resources["TextBrush"]! },
                        badge,
                    },
                },
            };
            host.Tapped += (_, _) => Model.SidebarSelection = item;
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
                Foreground = (IBrush)Resources["MutedTextBrush"]!,
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
                        Foreground = (IBrush)Resources["TextBrush"]!,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                };
                var captured = project;
                host.Tapped += (_, _) => Model.SelectProject(captured);
                ToolTip.SetTip(host, project.Name);
                NavList.Children.Add(host);
            }
        }
        NavSettings.Tapped += (_, _) => Model.SidebarSelection = SidebarItem.Settings;
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
            badge.Foreground = count > 0 ? (IBrush)Resources["AccentBrush"]! : Brushes.Transparent;
        }
    }

    /// <summary>主区路由：详情与新稿占用主区完整页面（UI-02）。</summary>
    private void RenderPage()
    {
        foreach (var (item, host, _) in _navItems)
        {
            host.Background = Model.SidebarSelection == item
                ? (IBrush)Resources["SelectedBrush"]!
                : Brushes.Transparent;
        }
        NavSettings.Background = Model.SidebarSelection == SidebarItem.Settings
            ? (IBrush)Resources["SelectedBrush"]!
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
            page = Model.SidebarSelection switch
            {
                SidebarItem.DraftBox => new DraftBoxPage(Model),
                SidebarItem.ClueDesk => new ClueDeskPage(Model),
                SidebarItem.Projects => new ProjectsPage(Model, null),
                SidebarItem.Todo => new ProjectsPage(Model, ProjectStatus.Todo),
                SidebarItem.Archived => new ProjectsPage(Model, ProjectStatus.Archived),
                SidebarItem.Settings => new SettingsPage(Model),
                _ => new DraftBoxPage(Model),
            };
        }
        PageHost.Content = page;
        UpdateBadges();
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

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        if (Model.ShowNewDraftPage || Model.SelectedDraft is not null) return;
        var files = e.DataTransfer.TryGetFiles().ToList();
        if (files is null || files.Count == 0) return;
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
}
