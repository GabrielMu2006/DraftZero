using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>01 草稿箱（UI-03 / W-001）：收纳、找回、筛选；空态两个强入口。</summary>
public sealed class DraftBoxPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly StackPanel _listPanel = new() { Spacing = 8 };

    public DraftBoxPage(AppViewModel model)
    {
        _model = model;
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };

        root.Children.Add(ArchiveUI.PageHeader("01", "草稿箱",
            $"共 {_model.Drafts.Count} 份草稿 · 未归组 {_model.UngroupedCount} · 待确认线索 {_model.PendingClueCount}"));

        // 筛选行
        var filterRow = ArchiveUI.HStack(6);
        foreach (DraftBoxFilter filter in Enum.GetValues<DraftBoxFilter>())
        {
            var f = filter;
            var button = new Button
            {
                Content = filter.DisplayName(),
                Padding = new Thickness(10, 4),
                FontSize = 12.5,
            };
            button.Click += (_, _) => { _model.DraftBoxFilter = f; Refresh(); };
            if (filter == _model.DraftBoxFilter)
            {
                button.Background = ArchiveUI.Selected;
            }
            filterRow.Children.Add(button);
        }
        filterRow.Children.Add(new Spacer());
        var importButton = ArchiveUI.SecondaryButton("导入文件（Ctrl+O）");
        importButton.Click += async (_, _) => await ImportAsync();
        filterRow.Children.Add(importButton);
        var linkButton = ArchiveUI.SecondaryButton("添加链接（Ctrl+L）");
        linkButton.Click += (_, _) => { _model.ShowAddLinkSheet = true; };
        filterRow.Children.Add(linkButton);
        Grid.SetRow(filterRow, 1);
        filterRow.Margin = new Thickness(28, 0, 28, 10);
        root.Children.Add(filterRow);

        // 列表
        var scroll = new ScrollViewer { Content = _listPanel, Padding = new Thickness(28, 0, 28, 20) };
        Grid.SetRow(scroll, 2);
        root.Children.Add(scroll);

        // 底部提示（QA 隔离横幅）
        var bottom = new StackPanel { Spacing = 0 };
        if (_model.WorkspaceOverrideDirectory is not null)
        {
            bottom.Children.Add(ArchiveUI.NoticeBar(
                $"QA 隔离工作区已启用（DZ_WORKSPACE_DIR={_model.WorkspaceOverrideDirectory}），当前数据不在默认位置。", ArchiveUI.Accent));
        }
        Grid.SetRow(bottom, 3);
        root.Children.Add(bottom);

        Content = root;
        Refresh();
    }

    private sealed class Spacer : Control
    {
        public Spacer() { HorizontalAlignment = HorizontalAlignment.Stretch; }
    }

    private void Refresh()
    {
        _listPanel.Children.Clear();

        if (_model.Drafts.Count == 0)
        {
            var newDraft = ArchiveUI.PrimaryButton("新建草稿（Ctrl+N）");
            newDraft.Click += (_, _) => _model.OpenNewDraftPage();
            var import = ArchiveUI.SecondaryButton("导入文件/链接");
            import.Click += async (_, _) => await ImportAsync();
            _listPanel.Children.Add(new Border
            {
                Padding = new Thickness(0, 120, 0, 0),
                Child = ArchiveUI.EmptyState(
                    "先把一句话、半篇文章或一个待办念头放进来。\n拖入 TXT / Markdown / PDF，或添加网页与 GitHub 链接。",
                    newDraft, import),
            });
            return;
        }

        var drafts = FilteredDrafts();
        if (drafts.Count == 0)
        {
            _listPanel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState(
                "当前筛选下没有草稿。")));
            return;
        }

        foreach (var draft in drafts)
        {
            _listPanel.Children.Add(DraftRow(draft));
        }
    }

    private List<Draft> FilteredDrafts()
    {
        IEnumerable<Draft> query = _model.Drafts;
        switch (_model.DraftBoxFilter)
        {
            case DraftBoxFilter.Ungrouped:
                query = query.Where(d => (_model.ProjectCounts.GetValueOrDefault(d.Id)) == 0);
                break;
            case DraftBoxFilter.RecentlyEdited:
                query = query.OrderByDescending(d => _model.LastEdited.GetValueOrDefault(d.Id, d.ImportedAt));
                break;
            case DraftBoxFilter.Snapshots:
                query = query.Where(d => d.SourceType is SourceType.Pdf or SourceType.Web or SourceType.GitHubFile);
                break;
            default:
                query = query.OrderByDescending(d => _model.LastEdited.GetValueOrDefault(d.Id, d.ImportedAt));
                break;
        }
        return query.ToList();
    }

    /// <summary>行式档案卡：标题、两行摘要、来源类型、可编辑/只读、所属项目。</summary>
    private Border DraftRow(Draft draft)
    {
        var projectNames = _model.DraftProjectNames.GetValueOrDefault(draft.Id) ?? [];
        var summary = draft.Content is { Length: > 0 } content
            ? string.Concat(content.Where(c => c != '\n' && c != '\r').Take(90)) + (content.Length > 90 ? "…" : "")
            : draft.HasExtractableText ? "（无正文预览）" : "无可用于关联的文字";

        var row = new StackPanel { Spacing = 4 };
        var titleRow = ArchiveUI.HStack(8);
        titleRow.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(draft.Title) ? "未命名草稿" : draft.Title,
            FontSize = 15.5,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        titleRow.Children.Add(ArchiveUI.StatusChip(ArchiveUI.SourceName(draft.SourceType),
            draft.SourceType is SourceType.Pdf or SourceType.Web or SourceType.GitHubFile ? ArchiveUI.MutedText : ArchiveUI.Confirmed));
        if (!draft.HasExtractableText)
        {
            titleRow.Children.Add(ArchiveUI.StatusChip("无可用于关联的文字", ArchiveUI.Danger));
        }
        row.Children.Add(titleRow);

        row.Children.Add(new TextBlock
        {
            Text = summary,
            FontSize = 12.5,
            Foreground = ArchiveUI.MutedText,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxHeight = 36,
            TextWrapping = TextWrapping.Wrap,
        });

        var metaRow = ArchiveUI.HStack(10);
        metaRow.Children.Add(new TextBlock
        {
            Text = (draft.IsEditable ? "可编辑" : "只读快照") + " · " + ArchiveUI.Relative(draft.ImportedAt),
            FontSize = 11.5,
            Foreground = ArchiveUI.MutedText,
        });
        if (projectNames.Count > 0)
        {
            metaRow.Children.Add(new TextBlock
            {
                Text = "属于：" + (projectNames.Count <= 2
                    ? string.Join("、", projectNames)
                    : $"{string.Join("、", projectNames.Take(2))} 等 {projectNames.Count} 个项目"),
                FontSize = 11.5,
                Foreground = ArchiveUI.Confirmed,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }
        row.Children.Add(metaRow);

        var card = ArchiveUI.Card(row, ArchiveUI.Raised);
        card.Tapped += (_, _) => _model.OpenDraft(draft);
        ToolTip.SetTip(card, draft.SourceLocation is { } loc ? $"来源：{loc}" : draft.Title);
        return card;
    }

    private async System.Threading.Tasks.Task ImportAsync()
    {
        var window = TopLevel.GetTopLevel(this) as Window;
        if (window is MainWindow main)
        {
            await main.PickAndImportAsync();
        }
    }
}
