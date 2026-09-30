using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>添加链接浮层（R-002）：网页 / GitHub 单文件直进；仓库打开勾选列表。</summary>
public sealed class AddLinkSheet : UserControl
{
    private AppViewModel? _model;
    private readonly TextBox _urlBox = new() { Watermark = "https://… 或 github.com/owner/repo", FontSize = 14 };
    private readonly TextBlock _error = new() { FontSize = 12, Foreground = ArchiveUI.Danger, TextWrapping = TextWrapping.Wrap, IsVisible = false };

    public AddLinkSheet()
    {
        var border = new Border
        {
            Background = ArchiveUI.Canvas,
            Opacity = 1,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Rule,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(20),
                MaxWidth = 560,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = BuildContent(),
            },
        };
        Content = border;
    }

    public void Show(AppViewModel model)
    {
        _model = model;
        IsVisible = true;
        _urlBox.Focus();
    }

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = "添加链接",
            FontSize = 19,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
        });
        panel.Children.Add(ArchiveUI.Muted("公开网页保存正文快照；GitHub 单文件直接导入；公开仓库会先打开文件列表勾选。断网后快照仍可读。", 12));
        panel.Children.Add(_urlBox);
        _urlBox.KeyDown += async (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter)
            {
                await SubmitAsync();
            }
        };
        panel.Children.Add(_error);

        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消");
        cancel.Click += (_, _) => Close();
        var ok = ArchiveUI.PrimaryButton("导入");
        ok.Click += async (_, _) => await SubmitAsync();
        row.Children.Add(cancel);
        row.Children.Add(ok);
        panel.Children.Add(row);
        return panel;
    }

    private async System.Threading.Tasks.Task SubmitAsync()
    {
        if (_model is null) return;
        _error.IsVisible = false;
        await _model.OpenLinkAsync(_urlBox.Text ?? "");
        if (_model.LinkError is { } linkError)
        {
            _error.Text = linkError;
            _error.IsVisible = true;
            return;
        }
        if (_model.RepoBrowse is null)
        {
            Close();
        }
    }

    public void Close()
    {
        IsVisible = false;
        _urlBox.Text = "";
        _error.IsVisible = false;
        if (_model is not null) _model.ShowAddLinkSheet = false;
    }
}

/// <summary>仓库文件勾选浮层（R-002）：列表、截断标记、取消零导入。</summary>
public sealed class RepoBrowseSheet : UserControl
{
    private AppViewModel? _model;
    private RepoBrowseState? _state;
    private readonly StackPanel _listPanel = new() { Spacing = 4 };
    private readonly TextBlock _title = new() { FontSize = 18, FontWeight = FontWeight.SemiBold, Foreground = ArchiveUI.TextBrush };
    private readonly TextBlock _warning = new() { FontSize = 12, Foreground = ArchiveUI.Accent, TextWrapping = TextWrapping.Wrap };

    public RepoBrowseSheet()
    {
        Content = new Border
        {
            Background = ArchiveUI.Canvas,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Rule,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(20),
                Width = 640,
                Height = 560,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = BuildContent(),
            },
        };
    }

    public void Show(RepoBrowseState state, AppViewModel model)
    {
        _state = state;
        _model = model;
        IsVisible = true;
        _title.Text = $"{state.Owner}/{state.Repo}（{state.Branch}）";
        _warning.Text = state.Truncated
            ? "⚠ 仓库文件列表不完整（GitHub 服务限制），以下仅是已取得的部分。"
            : $"共 {state.Entries.Count} 个文件；勾选要导入的 TXT/Markdown/PDF。";
        Refresh();
    }

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(_title);
        panel.Children.Add(_warning);
        var scroll = new ScrollViewer { Content = _listPanel, Height = 340 };
        panel.Children.Add(scroll);
        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消（不导入任何文件）");
        cancel.Click += (_, _) => Close();
        var import = ArchiveUI.PrimaryButton("导入勾选文件");
        import.Click += async (_, _) =>
        {
            if (_state is null || _model is null) return;
            if (_state.Checked.Count == 0) return;
            Close();
            await _model.ImportCheckedRepoFilesAsync();
        };
        row.Children.Add(cancel);
        row.Children.Add(import);
        panel.Children.Add(row);
        return panel;
    }

    private void Refresh()
    {
        _listPanel.Children.Clear();
        if (_state is null) return;
        foreach (var entry in _state.Entries)
        {
            var checkBox = new CheckBox
            {
                IsEnabled = entry.IsSupported && !entry.IsTooLarge,
            };
            checkBox.IsCheckedChanged += (_, _) =>
            {
                if (_state is null) return;
                if (checkBox.IsChecked == true) _state.Checked.Add(entry.Path);
                else _state.Checked.Remove(entry.Path);
            };
            var label = ArchiveUI.HStack(8);
            label.Children.Add(new TextBlock
            {
                Text = entry.Path,
                FontSize = 12.5,
                Foreground = entry.IsSupported ? ArchiveUI.TextBrush : ArchiveUI.MutedText,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            label.Children.Add(ArchiveUI.Muted(entry.IsSupported ? entry.SizeLabel : "不支持", 11));
            label.Children.Add(new Border());
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children = { checkBox, label },
            };
            _listPanel.Children.Add(row);
        }
    }

    private void Close()
    {
        IsVisible = false;
        if (_model is not null) _model.RepoBrowse = null;
    }
}

/// <summary>快速搜索（Ctrl+K）：标题/正文命中草稿与项目。</summary>
public sealed class QuickSearchSheet : UserControl
{
    private AppViewModel? _model;
    private readonly TextBox _query = new() { Watermark = "搜索草稿与项目…", FontSize = 16 };
    private readonly StackPanel _results = new() { Spacing = 6 };

    public QuickSearchSheet()
    {
        Content = new Border
        {
            Background = ArchiveUI.Canvas,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Rule,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(18),
                Width = 620,
                MaxHeight = 480,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Avalonia.Thickness(0, 80, 0, 0),
                Child = BuildContent(),
            },
        };
    }

    public void Show(AppViewModel model)
    {
        _model = model;
        IsVisible = true;
        _results.Children.Clear();
        _query.Text = "";
        _query.Focus();
    }

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(_query);
        _query.TextChanged += (_, _) => Refresh();
        _query.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Escape) Close();
        };
        panel.Children.Add(_results);
        panel.Children.Add(ArchiveUI.Muted("Esc 关闭；回车打开第一个结果。", 11));
        return panel;
    }

    private void Refresh()
    {
        _results.Children.Clear();
        if (_model is null) return;
        var q = (_query.Text ?? "").Trim();
        if (q.Length == 0) return;

        foreach (var project in _model.Projects
            .Where(p => p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).Take(5))
        {
            var p = project;
            var row = ArchiveUI.Card(new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    ArchiveUI.Body($"项目：{p.Name}", ArchiveUI.TextBrush, 13.5),
                    ArchiveUI.Muted($"{p.Status.DisplayName()} · {_model.ProjectMembers.GetValueOrDefault(p.Id)?.Count ?? 0} 份草稿", 11),
                },
            }, ArchiveUI.Surface);
            row.Tapped += (_, _) => { _model.SelectProject(p); Close(); };
            _results.Children.Add(row);
        }
        foreach (var draft in _model.Drafts
            .Where(d => (d.Title?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false)
                        || (d.Content?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false))
            .Take(10))
        {
            var d = draft;
            var row = ArchiveUI.Card(new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    ArchiveUI.Body(d.Title, ArchiveUI.TextBrush, 13.5),
                    ArchiveUI.Muted($"{ArchiveUI.SourceName(d.SourceType)} · {ArchiveUI.Relative(d.ImportedAt)}", 11),
                },
            }, ArchiveUI.Surface);
            row.Tapped += (_, _) => { _model.OpenDraft(d); Close(); };
            _results.Children.Add(row);
        }
        if (_results.Children.Count == 0)
        {
            _results.Children.Add(ArchiveUI.Muted("没有匹配的草稿或项目。", 12.5));
        }
    }

    private void Close() => IsVisible = false;
}

/// <summary>归入项目浮层（R-005：接受候选必须选现有项目或输入新项目名）。</summary>
public sealed class JoinProjectSheet : UserControl
{
    private AppViewModel? _model;
    private CandidatePair? _pair;
    private RemoteSuggestion? _suggestion;
    private Draft? _draft;
    private readonly TextBox _newName = new() { Watermark = "或输入新项目名", FontSize = 14 };

    public JoinProjectSheet()
    {
        Content = new Border
        {
            Background = ArchiveUI.Canvas,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Rule,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(20),
                Width = 480,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = BuildContent(),
            },
        };
    }

    public static void ShowForPair(MainWindow? owner, AppViewModel model, CandidatePair pair)
    {
        if (owner is null) return;
        owner.JoinProjectSheet.Show(model, pair, null, null);
    }

    public static void ShowForSuggestion(MainWindow? owner, AppViewModel model, RemoteSuggestion suggestion)
    {
        if (owner is null) return;
        owner.JoinProjectSheet.Show(model, null, suggestion, null);
    }

    public static void ShowForDraft(MainWindow? owner, AppViewModel model, Draft draft)
    {
        if (owner is null) return;
        owner.JoinProjectSheet.Show(model, null, null, draft);
    }

    public void Show(AppViewModel model, CandidatePair? pair, RemoteSuggestion? suggestion, Draft? draft)
    {
        _model = model;
        _pair = pair;
        _suggestion = suggestion;
        _draft = draft;
        IsVisible = true;
        _newName.Text = "";
        var list = this.FindControl<ListBox>("ProjectList");
        if (list is not null)
        {
            list.ItemsSource = model.Projects.Select(p => p.Name).ToList();
        }
    }

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        var title = new TextBlock
        {
            Text = "归入项目",
            FontSize = 19,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
        };
        panel.Children.Add(title);
        panel.Children.Add(ArchiveUI.Muted("候选不是归属：只有在这里选择项目后，草稿才会真正加入。", 12));
        panel.Children.Add(new TextBlock { Text = "现有项目：", FontSize = 13, Foreground = ArchiveUI.TextBrush });
        var projectList = new ListBox { Height = 160, FontSize = 13.5, Name = "ProjectList" };
        panel.Children.Add(projectList);
        panel.Children.Add(new TextBlock { Text = "新建项目：", FontSize = 13, Foreground = ArchiveUI.TextBrush });
        panel.Children.Add(_newName);

        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消");
        cancel.Click += (_, _) => Close();
        var ok = ArchiveUI.PrimaryButton("确认归入");
        ok.Click += async (_, _) =>
        {
            if (_model is null) return;
            string? target = _newName.Text?.Trim();
            if (string.IsNullOrEmpty(target) && projectList.SelectedIndex is int idx && idx >= 0)
            {
                target = _model.Projects[idx].Name;
            }
            if (string.IsNullOrEmpty(target)) return;

            Project? project = _model.Projects.FirstOrDefault(p => p.Name == target);
            if (project is null)
            {
                project = await _model.CreateProjectAsyncWithReturn(target);
            }
            if (_pair is { } pair) await _model.AcceptPairAsync(pair, project);
            if (_suggestion is { } suggestion) await _model.AcceptRemoteSuggestionAsync(suggestion, project);
            if (_draft is { } draft) await _model.AddDraftToProjectAsync(draft.Id, project.Id);
            Close();
        };
        row.Children.Add(cancel);
        row.Children.Add(ok);
        panel.Children.Add(row);
        return panel;
    }

    public void Close() => IsVisible = false;
}

/// <summary>合并草稿浮层（R-007：两份及以上、指定顺序、来源保留）。</summary>
public sealed class MergeSheet : UserControl
{
    private AppViewModel? _model;
    private Draft? _primary;
    private readonly StackPanel _candidatesPanel = new() { Spacing = 4 };
    private readonly HashSet<Guid> _selected = [];
    private readonly List<Guid> _ordered = [];

    public MergeSheet()
    {
        Content = new Border
        {
            Background = ArchiveUI.Canvas,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Rule,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(20),
                Width = 560,
                MaxHeight = 560,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = BuildContent(),
            },
        };
    }

    public static void Show(MainWindow? owner, AppViewModel model, Draft primary)
    {
        if (owner is null) return;
        owner.MergeSheet.Show(model, primary);
    }

    public void Show(AppViewModel model, Draft primary)
    {
        _model = model;
        _primary = primary;
        _selected.Clear();
        _ordered.Clear();
        _selected.Add(primary.Id);
        _ordered.Add(primary.Id);
        IsVisible = true;
        Refresh();
    }

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = "合并草稿",
            FontSize = 19,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
        });
        panel.Children.Add(ArchiveUI.Muted("勾选两份及以上，按勾选顺序合并为新草稿；来源保留不变。", 12));
        var scroll = new ScrollViewer { Content = _candidatesPanel, MaxHeight = 300 };
        panel.Children.Add(scroll);
        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消");
        cancel.Click += (_, _) => Close();
        var merge = ArchiveUI.PrimaryButton("合并所选");
        merge.Click += async (_, _) =>
        {
            if (_model is null || _ordered.Count < 2) return;
            var title = await TextInputDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "新草稿标题", "留空则自动命名（合并：…）", "");
            await _model.MergeDraftsAsync(_ordered.ToList(), string.IsNullOrWhiteSpace(title) ? null : title!.Trim());
            Close();
        };
        row.Children.Add(cancel);
        row.Children.Add(merge);
        panel.Children.Add(row);
        return panel;
    }

    private void Refresh()
    {
        _candidatesPanel.Children.Clear();
        if (_model is null) return;
        foreach (var draft in _model.Drafts)
        {
            var id = draft.Id;
            var checkBox = new CheckBox { IsChecked = _selected.Contains(id) };
            checkBox.IsCheckedChanged += (_, _) =>
            {
                if (checkBox.IsChecked == true)
                {
                    _selected.Add(id);
                    _ordered.Add(id);
                }
                else
                {
                    _selected.Remove(id);
                    _ordered.Remove(id);
                }
            };
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    checkBox,
                    new TextBlock
                    {
                        Text = draft.Title + (id == _primary?.Id ? "（当前）" : ""),
                        FontSize = 13,
                        Foreground = ArchiveUI.TextBrush,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                },
            };
            _candidatesPanel.Children.Add(row);
        }
    }

    private void Close() => IsVisible = false;
}

/// <summary>深链写入确认（W-009：拒绝零写入）。</summary>
public sealed class DeepLinkConfirmSheet : UserControl
{
    private PendingDeepLinkWrite? _pending;

    public DeepLinkConfirmSheet()
    {
        Content = new Border
        {
            Background = ArchiveUI.Canvas,
            Child = new Border
            {
                Background = ArchiveUI.Raised,
                CornerRadius = new Avalonia.CornerRadius(12),
                BorderBrush = ArchiveUI.Danger,
                BorderThickness = new Avalonia.Thickness(1),
                Padding = new Avalonia.Thickness(20),
                Width = 520,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = BuildContent(),
            },
        };
    }

    private TextBlock? _titleText;
    private TextBlock? _messageText;

    private Control BuildContent()
    {
        var panel = new StackPanel { Spacing = 12 };
        _titleText = new TextBlock
        {
            Text = "外部请求确认",
            FontSize = 19,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
        };
        _messageText = new TextBlock
        {
            FontSize = 13.5,
            Foreground = ArchiveUI.TextBrush,
            TextWrapping = TextWrapping.Wrap,
        };
        panel.Children.Add(_titleText);
        panel.Children.Add(_messageText);
        panel.Children.Add(ArchiveUI.Muted("拒绝或关闭本窗口都不会写入任何数据。", 11.5));

        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var deny = ArchiveUI.SecondaryButton("拒绝");
        deny.Foreground = ArchiveUI.Danger;
        deny.Click += (_, _) => { _pending = null; IsVisible = false; };
        var allow = ArchiveUI.PrimaryButton("允许执行");
        allow.Click += (_, _) =>
        {
            var action = _pending?.Action;
            _pending = null;
            IsVisible = false;
            if (action is not null) _ = action();
        };
        row.Children.Add(deny);
        row.Children.Add(allow);
        panel.Children.Add(row);
        return panel;
    }

    public void Show(PendingDeepLinkWrite? pending)
    {
        _pending = pending;
        IsVisible = pending is not null;
        if (pending is not null)
        {
            _titleText!.Text = pending.Title;
            _messageText!.Text = pending.Message;
        }
    }
}
