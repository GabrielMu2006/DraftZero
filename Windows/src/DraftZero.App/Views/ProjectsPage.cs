using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>03/04/05 项目列表（UI-06 / W-005/W-007）：状态筛选、标签、草稿数。</summary>
public sealed class ProjectsPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly ProjectStatus? _fixedFilter;
    private readonly StackPanel _listPanel = new() { Spacing = 8 };

    public ProjectsPage(AppViewModel model, ProjectStatus? fixedFilter)
    {
        _model = model;
        _fixedFilter = fixedFilter;
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };

        var (index, title, subtitle) = fixedFilter switch
        {
            ProjectStatus.Todo => ("04", "TODO", "需要推进的想法项目"),
            ProjectStatus.Archived => ("05", "暂时封存", "封存可逆；内容随时找回"),
            _ => ("03", "想法项目", "人工确认的归类结果"),
        };
        root.Children.Add(ArchiveUI.PageHeader(index, title, subtitle));

        var scroll = new ScrollViewer { Content = _listPanel, Padding = new Thickness(28, 0, 28, 20) };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);

        var footer = ArchiveUI.HStack(8);
        footer.Margin = new Thickness(28, 0, 28, 18);
        var create = ArchiveUI.PrimaryButton("新建项目");
        create.Click += async (_, _) =>
        {
            var name = await TextInputDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "新建项目", "项目名称（默认状态：待整理）", "");
            if (!string.IsNullOrWhiteSpace(name))
            {
                await _model.CreateProjectAsync(name.Trim());
                Refresh();
            }
        };
        footer.Children.Add(create);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);

        Content = root;
        Refresh();
    }

    private void Refresh()
    {
        _listPanel.Children.Clear();
        var projects = _fixedFilter is { } status
            ? _model.Projects.Where(p => p.Status == status).ToList()
            : _model.Projects.ToList();

        if (projects.Count == 0)
        {
            _listPanel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState(
                _fixedFilter == ProjectStatus.Archived
                    ? "没有暂时封存的项目。"
                    : "还没有项目。从线索台接受建议，或手动新建一个。")));
            return;
        }

        foreach (var project in projects)
        {
            _listPanel.Children.Add(ProjectCard(project));
        }
    }

    private Border ProjectCard(Project project)
    {
        var memberCount = _model.ProjectMembers.GetValueOrDefault(project.Id)?.Count ?? 0;
        var tags = _model.ProjectTags.GetValueOrDefault(project.Id) ?? [];

        var row = new StackPanel { Spacing = 4 };
        var titleRow = ArchiveUI.HStack(8);
        titleRow.Children.Add(new TextBlock
        {
            Text = project.Name,
            FontSize = 15.5,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        titleRow.Children.Add(ArchiveUI.StatusChip(project.Status.DisplayName(),
            project.Status == ProjectStatus.Archived ? ArchiveUI.Danger : ArchiveUI.Confirmed));
        row.Children.Add(titleRow);

        var metaRow = ArchiveUI.HStack(8);
        metaRow.Children.Add(ArchiveUI.Muted($"{memberCount} 份草稿 · 创建于 {ArchiveUI.Relative(project.CreatedAt)}", 11.5));
        foreach (var tag in tags)
        {
            metaRow.Children.Add(ArchiveUI.StatusChip("#" + tag.Name, ArchiveUI.Accent));
        }
        row.Children.Add(metaRow);

        var card = ArchiveUI.Card(row, ArchiveUI.Raised);
        card.Tapped += (_, _) => _model.SelectProject(project);
        return card;
    }
}

/// <summary>多选对话框（选择项目/草稿）。</summary>
public static class ChoiceDialog
{
    public static async System.Threading.Tasks.Task<int> ShowAsync(Window? owner,
        string title, IReadOnlyList<string> options, int initial)
    {
        if (owner is null || options.Count == 0) return -1;
        var tcs = new System.Threading.Tasks.TaskCompletionSource<int>();
        var dialog = new Window
        {
            Title = title,
            Width = 460,
            Height = Math.Min(520, 140 + options.Count * 42),
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = ArchiveUI.Canvas,
        };
        var panel = new StackPanel { Margin = new Thickness(16), Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeight.SemiBold, Foreground = ArchiveUI.TextBrush });
        var list = new ListBox { FontSize = 14 };
        foreach (var option in options) list.Items.Add(option);
        if (initial >= 0 && initial < options.Count) list.SelectedIndex = initial;
        list.DoubleTapped += (_, _) => { tcs.TrySetResult(list.SelectedIndex); dialog.Close(); };
        panel.Children.Add(list);
        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消");
        cancel.Click += (_, _) => { tcs.TrySetResult(-1); dialog.Close(); };
        var ok = ArchiveUI.PrimaryButton("确定");
        ok.Click += (_, _) => { tcs.TrySetResult(list.SelectedIndex); dialog.Close(); };
        row.Children.Add(cancel);
        row.Children.Add(ok);
        panel.Children.Add(row);
        dialog.Content = panel;
        await dialog.ShowDialog(owner);
        return await tcs.Task;
    }
}

/// <summary>单行文本输入对话框（新建项目/标签/重命名等）。</summary>
public static class TextInputDialog
{
    public static async System.Threading.Tasks.Task<string?> ShowAsync(Window? owner,
        string title, string message, string initial)
    {
        if (owner is null) return null;
        var tcs = new System.Threading.Tasks.TaskCompletionSource<string?>();
        var dialog = new Window
        {
            Title = title,
            Width = 440,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = ArchiveUI.Canvas,
        };
        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeight.SemiBold, Foreground = ArchiveUI.TextBrush });
        panel.Children.Add(ArchiveUI.Muted(message, 12.5));
        var input = new TextBox { Text = initial, FontSize = 14.5 };
        panel.Children.Add(input);
        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        var cancel = ArchiveUI.SecondaryButton("取消");
        cancel.Click += (_, _) => { tcs.TrySetResult(null); dialog.Close(); };
        var ok = ArchiveUI.PrimaryButton("确定");
        ok.Click += (_, _) => { tcs.TrySetResult(input.Text); dialog.Close(); };
        row.Children.Add(cancel);
        row.Children.Add(ok);
        panel.Children.Add(row);
        dialog.Content = panel;
        input.AttachedToVisualTree += (_, _) => input.Focus();
        await dialog.ShowDialog(owner);
        return await tcs.Task;
    }
}
