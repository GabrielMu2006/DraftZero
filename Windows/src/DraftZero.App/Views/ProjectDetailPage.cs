using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>项目档案（UI-06 / W-005/W-006/W-007）：成员/演化切换、状态、标签、一稿多项目。</summary>
public sealed class ProjectDetailPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly Project _project;
    private bool _showEvolution;
    private readonly ContentControl _bodyHost = new();

    public ProjectDetailPage(AppViewModel model, Project project)
    {
        _model = model;
        _project = project;
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };

        // 头部：返回 + 名称 + 状态 + 标签
        var header = new StackPanel { Margin = new Thickness(28, 22, 28, 10), Spacing = 8 };
        var back = ArchiveUI.SecondaryButton("← 返回项目列表");
        back.Click += (_, _) => { _model.SelectedProject = null; };
        header.Children.Add(back);

        var titleRow = ArchiveUI.HStack(12);
        titleRow.Children.Add(new TextBlock
        {
            Text = _project.Name,
            FontSize = 30,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var statusButton = ArchiveUI.SecondaryButton(_project.Status.DisplayName());
        statusButton.Click += async (_, _) =>
        {
            var choice = await ChoiceDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window, "项目状态",
                Enum.GetValues<ProjectStatus>().Select(s => s.DisplayName()).ToArray(),
                Array.IndexOf(Enum.GetValues<ProjectStatus>(), _project.Status));
            if (choice >= 0)
            {
                await _model.SetProjectStatusAsync(_project, Enum.GetValues<ProjectStatus>()[choice]);
            }
        };
        titleRow.Children.Add(statusButton);
        foreach (var tag in _model.ProjectTags.GetValueOrDefault(_project.Id) ?? [])
        {
            titleRow.Children.Add(ArchiveUI.StatusChip("#" + tag.Name, ArchiveUI.Accent));
        }
        header.Children.Add(titleRow);
        root.Children.Add(header);

        // 分段 + 操作
        var toolbar = ArchiveUI.HStack(8);
        toolbar.Margin = new Thickness(28, 0, 28, 10);
        var membersTab = ArchiveUI.SecondaryButton("成员");
        var evolutionTab = ArchiveUI.SecondaryButton("演化");
        membersTab.Click += (_, _) => { _showEvolution = false; RefreshTabs(membersTab, evolutionTab); };
        evolutionTab.Click += (_, _) => { _showEvolution = true; RefreshTabs(membersTab, evolutionTab); };
        toolbar.Children.Add(membersTab);
        toolbar.Children.Add(evolutionTab);
        toolbar.Children.Add(NewSpacer());

        var addTag = ArchiveUI.SecondaryButton("添加标签");
        addTag.Click += async (_, _) =>
        {
            var name = await TextInputDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "添加标签", "标签名称（同名不会重复创建）", "");
            if (!string.IsNullOrWhiteSpace(name))
            {
                await _model.AddTagAsync(name.Trim(), _project.Id);
            }
        };
        toolbar.Children.Add(addTag);
        var rename = ArchiveUI.SecondaryButton("重命名");
        rename.Click += async (_, _) =>
        {
            var name = await TextInputDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "重命名项目", "新的项目名称", _project.Name);
            if (!string.IsNullOrWhiteSpace(name))
            {
                await _model.RenameProjectAsync(_project, name.Trim());
            }
        };
        toolbar.Children.Add(rename);
        var delete = ArchiveUI.SecondaryButton("删除项目");
        delete.Foreground = ArchiveUI.Danger;
        delete.Click += async (_, _) =>
        {
            var choice = await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "删除项目", $"删除项目「{_project.Name}」？\n成员草稿不会被删除：仍属于其他项目的继续留在那里，否则回到未归组区。",
                ("取消", false), ("删除项目", true));
            if (choice == 1)
            {
                await _model.DeleteProjectAsync(_project);
            }
        };
        toolbar.Children.Add(delete);
        Grid.SetRow(toolbar, 1);
        root.Children.Add(toolbar);

        Grid.SetRow(_bodyHost, 2);
        root.Children.Add(_bodyHost);

        var footer = ArchiveUI.Muted("以下文字事件列表即完整演化记录（已确认事实，按时间排序）；未确认候选不混入。", 11.5);
        footer.Margin = new Thickness(28, 0, 28, 14);
        Grid.SetRow(footer, 3);
        root.Children.Add(footer);

        Content = root;
        RefreshTabs(membersTab, evolutionTab);
    }

    private static Control NewSpacer() => new Border();

    private void RefreshTabs(Button membersTab, Button evolutionTab)
    {
        membersTab.Background = _showEvolution ? Brushes.Transparent : ArchiveUI.Selected;
        evolutionTab.Background = _showEvolution ? ArchiveUI.Selected : Brushes.Transparent;
        _bodyHost.Content = _showEvolution ? BuildEvolution() : BuildMembers();
    }

    private Control BuildMembers()
    {
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(28, 0, 28, 10) };
        var members = _model.ProjectMembers.GetValueOrDefault(_project.Id) ?? [];
        if (members.Count == 0)
        {
            panel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState(
                "还没有成员草稿。从草稿箱右键加入，或在线索台接受建议。")));
            return panel;
        }
        foreach (var draft in members)
        {
            var row = ArchiveUI.HStack(8);
            row.Children.Add(new TextBlock
            {
                Text = draft.Title,
                FontSize = 14,
                Foreground = ArchiveUI.TextBrush,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            row.Children.Add(ArchiveUI.Muted(ArchiveUI.SourceName(draft.SourceType), 11));
            // 一稿多项目展示
            var owning = _model.DraftProjectNames.GetValueOrDefault(draft.Id) ?? [];
            if (owning.Count > 1)
            {
                row.Children.Add(ArchiveUI.Muted($"属于 {owning.Count} 个项目", 11));
            }
            var spacer = new Border();
            row.Children.Add(spacer);
            var open = ArchiveUI.SecondaryButton("打开");
            open.Click += (_, _) => _model.OpenDraft(draft);
            row.Children.Add(open);
            var remove = ArchiveUI.SecondaryButton("移出");
            remove.Click += async (_, _) => await _model.RemoveDraftFromProjectAsync(draft.Id, _project.Id);
            row.Children.Add(remove);
            panel.Children.Add(ArchiveUI.Card(row, ArchiveUI.Raised));
        }

        // 加入成员
        var addRow = ArchiveUI.HStack(8);
        var add = ArchiveUI.SecondaryButton("把草稿加入本项目…");
        add.Click += async (_, _) =>
        {
            var ungrouped = _model.Drafts
                .Where(d => !(_model.ProjectMembers.GetValueOrDefault(_project.Id) ?? []).Any(m => m.Id == d.Id))
                .ToList();
            if (ungrouped.Count == 0) return;
            var choice = await ChoiceDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window, "加入草稿",
                ungrouped.Select(d => d.Title).ToArray(), -1);
            if (choice >= 0)
            {
                await _model.AddDraftToProjectAsync(ungrouped[choice].Id, _project.Id);
            }
        };
        addRow.Children.Add(add);
        panel.Children.Add(addRow);
        return panel;
    }

    /// <summary>演化：时间顺序展示已保存的版本、拆分、合并、衍生、手动关联（R-007）。</summary>
    private Control BuildEvolution()
    {
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(28, 0, 28, 10) };
        panel.Children.Add(ArchiveUI.Muted("正在读取演化记录…", 12));
        _ = LoadEvolutionAsync(panel);
        return panel;
    }

    private async System.Threading.Tasks.Task LoadEvolutionAsync(StackPanel panel)
    {
        var memberIds = (_model.ProjectMembers.GetValueOrDefault(_project.Id) ?? []).Select(d => d.Id).ToHashSet();
        var events = new List<(DateTime Time, string Line, Guid? DraftId)>();
        foreach (var draftId in memberIds)
        {
            var draft = _model.Drafts.FirstOrDefault(d => d.Id == draftId);
            if (draft is not null)
            {
                events.Add((draft.ImportedAt, $"导入「{draft.Title}」（{ArchiveUI.SourceName(draft.SourceType)}）", draftId));
                var lastEdited = _model.LastEdited.GetValueOrDefault(draftId);
                if (lastEdited != default)
                {
                    events.Add((lastEdited, $"编辑「{draft.Title}」留下新版本", draftId));
                }
            }
        }
        foreach (var relation in await _model.LoadRelationsForMembersAsync(memberIds))
        {
            var sourceTitle = _model.DraftTitle(relation.SourceDraftId) ?? "来源已删除";
            var targetTitle = _model.DraftTitle(relation.TargetDraftId) ?? "目标已删除";
            var note = relation.Note is { Length: > 0 } ? $"（{relation.Note}）" : "";
            events.Add((relation.CreatedAt, $"{relation.Type.DisplayName()}：「{sourceTitle}」 → 「{targetTitle}」{note}",
                memberIds.Contains(relation.SourceDraftId) ? relation.SourceDraftId
                : memberIds.Contains(relation.TargetDraftId) ? relation.TargetDraftId : null));
        }

        panel.Children.Clear();
        if (events.Count == 0)
        {
            panel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState("还没有可追溯的演化记录。")));
            return;
        }
        events.Sort((a, b) => a.Time.CompareTo(b.Time));
        foreach (var (time, line, draftId) in events)
        {
            var row = ArchiveUI.HStack(10);
            row.Children.Add(new TextBlock
            {
                Text = time.ToLocalTime().ToString("MM-dd HH:mm"),
                FontSize = 11.5,
                Foreground = ArchiveUI.MutedText,
                VerticalAlignment = VerticalAlignment.Center,
            });
            row.Children.Add(new TextBlock
            {
                Text = line,
                FontSize = 13,
                Foreground = ArchiveUI.TextBrush,
                TextWrapping = TextWrapping.Wrap,
            });
            if (draftId is { } id && memberIds.Contains(id))
            {
                var open = ArchiveUI.SecondaryButton("打开");
                open.Click += (_, _) =>
                {
                    if (_model.Drafts.FirstOrDefault(d => d.Id == id) is { } draft)
                    {
                        _model.OpenDraft(draft);
                    }
                };
                row.Children.Add(open);
            }
            panel.Children.Add(ArchiveUI.Card(row, ArchiveUI.Raised));
        }
    }
}
