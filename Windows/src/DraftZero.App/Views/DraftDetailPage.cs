using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.App.Services;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>
/// 草稿详情（UI-07 / W-003/W-006/W-007）：阅读/编辑、只读快照与可编辑副本、
/// 版本列表与对比恢复、拆分/合并、关系与"来源已删除"、PDF 应用内页预览、删除影响提示。
/// </summary>
public sealed class DraftDetailPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly Draft _draft;
    private readonly IPdfPageRenderer _pdfRenderer;
    private readonly TextBox? _editor;
    private readonly TextBlock? _saveState;
    private readonly StackPanel _sidePanel = new() { Spacing = 10 };
    private readonly ContentControl _pdfHost = new();
    private int _pdfPage = 1;
    private int _pdfPageCount;
    private Image? _pdfImage;

    public DraftDetailPage(AppViewModel model, Draft draft, IPdfPageRenderer pdfRenderer)
    {
        _model = model;
        _draft = draft;
        _pdfRenderer = pdfRenderer;

        var root = new Grid
        {
            RowDefinitions = new RowDefinitions("Auto,*,Auto"),
            ColumnDefinitions = new ColumnDefinitions("*"),
        };

        var header = new StackPanel { Margin = new Thickness(28, 20, 28, 10), Spacing = 6 };
        var topRow = ArchiveUI.HStack(10);
        var back = ArchiveUI.SecondaryButton("← 返回");
        back.Click += async (_, _) =>
        {
            if (_editor is not null && _draft.IsEditable)
            {
                await _model.FlushVersionAsync(_draft.Id);
            }
            _model.SelectedDraftId = null;
        };
        topRow.Children.Add(back);
        topRow.Children.Add(ArchiveUI.StatusChip(ArchiveUI.SourceName(_draft.SourceType), ArchiveUI.MutedText));
        if (!_draft.IsEditable)
        {
            topRow.Children.Add(ArchiveUI.StatusChip("只读快照", ArchiveUI.Accent));
        }
        if (!_draft.HasExtractableText)
        {
            topRow.Children.Add(ArchiveUI.StatusChip("无可用于关联的文字", ArchiveUI.Danger));
        }
        header.Children.Add(topRow);
        header.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(_draft.Title) ? "未命名草稿" : _draft.Title,
            FontSize = 28,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.TextBrush,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 700,
        });
        header.Children.Add(ArchiveUI.Muted(
            (_draft.SourceLocation is { } loc ? $"来源：{loc} · " : "") +
            $"导入于 {ArchiveUI.Relative(_draft.ImportedAt)}" +
            (_draft.SourceVersionSha is { } sha ? $" · 版本 {sha[..Math.Min(10, sha.Length)]}" : ""), 11.5));
        root.Children.Add(header);

        // 正文区 + 右侧检查栏
        var bodyGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,320") };
        var bodyPanel = new StackPanel { Spacing = 10, Margin = new Thickness(28, 0, 14, 10), MaxWidth = 760 };

        if (_draft.IsEditable)
        {
            _editor = new TextBox
            {
                Text = _draft.Content ?? "",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 15,
                MinHeight = 420,
                LineHeight = 24,
            };
            var saveIndicator = new TextBlock { FontSize = 11.5, Foreground = ArchiveUI.MutedText, Text = "已保存" };
            _saveState = saveIndicator;
            _editor.TextChanged += async (_, _) =>
            {
                saveIndicator.Text = "正在保存…";
                saveIndicator.Foreground = ArchiveUI.MutedText;
                await _model.SaveEditAsync(_draft.Id, _editor.Text ?? "");
                // 保存完成后按真实状态恢复反馈（失败要可见，不能停在"正在保存…"）
                switch (_model.EditSaveState)
                {
                    case AppViewModel.EditSaveStateKind.Saved:
                        saveIndicator.Text = "已保存";
                        saveIndicator.Foreground = ArchiveUI.Confirmed;
                        break;
                    case AppViewModel.EditSaveStateKind.Failed:
                        saveIndicator.Text = $"保存失败：{_model.EditSaveError ?? "请重试"}";
                        saveIndicator.Foreground = ArchiveUI.Danger;
                        break;
                    default:
                        saveIndicator.Text = "已保存";
                        break;
                }
            };
            bodyPanel.Children.Add(saveIndicator);
            bodyPanel.Children.Add(_editor);
        }
        else if (_draft.SourceType == SourceType.Pdf && _draft.SnapshotFileURL is not null)
        {
            // PDF 应用内页预览（W-003：不降级为外部阅读器）
            bodyPanel.Children.Add(_pdfHost);
        }
        else
        {
            // 只读快照全文
            bodyPanel.Children.Add(ArchiveUI.Card(new TextBox
            {
                Text = _draft.Content ?? "（无可用于关联的文字）",
                IsReadOnly = true,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 14.5,
                MinHeight = 300,
                Background = ArchiveUI.Surface,
            }, ArchiveUI.Raised));
        }

        var copyButton = ArchiveUI.SecondaryButton(_draft.IsEditable ? "从当前内容衍生新草稿" : "创建可编辑副本");
        copyButton.Click += async (_, _) => await _model.CreateEditableCopyAsync(_draft);
        bodyPanel.Children.Add(copyButton);
        var actionsRow = ArchiveUI.HStack(8);
        var splitButton = ArchiveUI.SecondaryButton("拆分段落…");
        splitButton.Click += async (_, _) => await SplitAsync();
        actionsRow.Children.Add(splitButton);
        var mergeButton = ArchiveUI.SecondaryButton("与其他草稿合并…");
        mergeButton.Click += (_, _) => MergeSheet.Show(TopLevel.GetTopLevel(this) as MainWindow, _model, _draft);
        actionsRow.Children.Add(mergeButton);
        var searchInClues = ArchiveUI.SecondaryButton("在线索台查看");
        searchInClues.Click += (_, _) => _model.SidebarSelection = SidebarItem.ClueDesk;
        actionsRow.Children.Add(searchInClues);
        bodyPanel.Children.Add(actionsRow);
        Grid.SetColumn(bodyPanel, 0);
        bodyGrid.Children.Add(bodyPanel);

        _sidePanel.Margin = new Thickness(0, 0, 24, 10);
        Grid.SetColumn(_sidePanel, 1);
        bodyGrid.Children.Add(_sidePanel);
        Grid.SetRow(bodyGrid, 1);
        root.Children.Add(bodyGrid);

        // 底部：删除
        var footer = ArchiveUI.HStack(8);
        footer.Margin = new Thickness(28, 6, 28, 16);
        var delete = ArchiveUI.SecondaryButton("删除草稿…");
        delete.Foreground = ArchiveUI.Danger;
        delete.Click += async (_, _) => await DeleteAsync();
        footer.Children.Add(delete);
        footer.Children.Add(ArchiveUI.Muted("删除前会显示影响：所属项目、版本数与 PDF 快照。", 11.5));
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);

        Content = root;
        _ = LoadSidePanelAsync();
        if (_draft.SourceType == SourceType.Pdf && _draft.SnapshotFileURL is not null)
        {
            _ = LoadPdfAsync();
        }
    }

    private async System.Threading.Tasks.Task LoadPdfAsync()
    {
        var (pageCount, error) = await _pdfRenderer.GetPageCountAsync(_draft.SnapshotFileURL!);
        _pdfPageCount = pageCount;
        if (error is not null)
        {
            _pdfHost.Content = ArchiveUI.Card(ArchiveUI.NoticeBar(error, ArchiveUI.Danger));
            return;
        }
        var panel = new StackPanel { Spacing = 8 };
        var navRow = ArchiveUI.HStack(8);
        var prev = ArchiveUI.SecondaryButton("上一页");
        var next = ArchiveUI.SecondaryButton("下一页");
        var pageLabel = new TextBlock { FontSize = 12.5, Foreground = ArchiveUI.MutedText, VerticalAlignment = VerticalAlignment.Center };
        _pdfImage = new Image { MaxWidth = 680 };
        prev.Click += async (_, _) => { if (_pdfPage > 1) { _pdfPage--; await RenderCurrentPageAsync(pageLabel); } };
        next.Click += async (_, _) => { if (_pdfPage < _pdfPageCount) { _pdfPage++; await RenderCurrentPageAsync(pageLabel); } };
        navRow.Children.Add(prev);
        navRow.Children.Add(pageLabel);
        navRow.Children.Add(next);
        panel.Children.Add(navRow);
        panel.Children.Add(new Border
        {
            Child = _pdfImage,
            Background = ArchiveUI.Surface,
            CornerRadius = new Avalonia.CornerRadius(8),
            Padding = new Thickness(6),
        });
        panel.Children.Add(ArchiveUI.Muted("PDF 快照只读；原文与远端内容不受应用影响。", 11));
        _pdfHost.Content = panel;
        await RenderCurrentPageAsync(pageLabel);
    }

    private async System.Threading.Tasks.Task RenderCurrentPageAsync(TextBlock pageLabel)
    {
        if (_draft.SnapshotFileURL is null) return;
        pageLabel.Text = $"第 {_pdfPage} / {_pdfPageCount} 页";
        var result = await _pdfRenderer.RenderPageAsync(_draft.SnapshotFileURL, _pdfPage, 660);
        if (result.Image is not null)
        {
            _pdfImage!.Source = result.Image;
        }
        else if (result.Error is not null)
        {
            pageLabel.Text = result.Error;
        }
    }

    private async System.Threading.Tasks.Task LoadSidePanelAsync()
    {
        _sidePanel.Children.Clear();

        // 归属项目
        var projects = await _model.LoadRelationsForMembersAsync([_draft.Id]);
        var owning = await _model.DatabaseProjectsContaining(_draft.Id);
        var memberCard = new StackPanel { Spacing = 6 };
        memberCard.Children.Add(ArchiveUI.SectionTitle("归属"));
        if (owning.Count == 0)
        {
            memberCard.Children.Add(ArchiveUI.Muted("未归组。可从线索台接受建议，或加入项目。", 12));
        }
        else
        {
            foreach (var project in owning)
            {
                var row = ArchiveUI.HStack(6);
                row.Children.Add(ArchiveUI.Body(project.Name, ArchiveUI.Confirmed, 12.5));
                var remove = ArchiveUI.SecondaryButton("移出");
                remove.Padding = new Thickness(6, 2);
                remove.Click += async (_, _) => { await _model.RemoveDraftFromProjectAsync(_draft.Id, project.Id); await LoadSidePanelAsync(); };
                row.Children.Add(remove);
                memberCard.Children.Add(row);
            }
        }
        var join = ArchiveUI.SecondaryButton("加入项目…");
        join.Click += (_, _) => JoinProjectSheet.ShowForDraft(TopLevel.GetTopLevel(this) as MainWindow, _model, _draft);
        memberCard.Children.Add(join);
        _sidePanel.Children.Add(ArchiveUI.Card(memberCard, ArchiveUI.Raised));

        // 版本（R-006）
        var versions = await _model.DatabaseVersions(_draft.Id);
        var versionCard = new StackPanel { Spacing = 6 };
        versionCard.Children.Add(ArchiveUI.SectionTitle($"版本（{versions.Count}）"));
        foreach (var version in versions.Take(8))
        {
            var row = ArchiveUI.HStack(6);
            row.Children.Add(new TextBlock
            {
                Text = $"{version.CreatedAt.ToLocalTime():MM-dd HH:mm} · {version.Origin.DisplayName()}",
                FontSize = 11.5,
                Foreground = ArchiveUI.MutedText,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var spacer = new Border();
            row.Children.Add(spacer);
            var compare = ArchiveUI.SecondaryButton("对比");
            compare.Padding = new Thickness(6, 2);
            var v = version;
            // 任意版本 vs 当前内容（W-006/R-006：比较产生新版本的历史任一点）
            compare.Click += (_, _) => VersionCompareDialog.Show(
                TopLevel.GetTopLevel(this) as Window, v.Content,
                _editor?.Text ?? _draft.Content ?? "");
            row.Children.Add(compare);
            var restore = ArchiveUI.SecondaryButton("恢复");
            restore.Padding = new Thickness(6, 2);
            restore.Click += async (_, _) =>
            {
                var choice = await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                    "恢复旧版", "恢复会产生一个新版本，不抹掉中间历史。",
                    ("取消", false), ("恢复", false));
                if (choice == 1)
                {
                    await _model.RestoreVersionAsync(v);
                    await ReloadSelfAsync();
                }
            };
            row.Children.Add(restore);
            versionCard.Children.Add(row);
        }
        if (versions.Count > 1)
        {
            var compareLatest = ArchiveUI.SecondaryButton("对比最近两版");
            compareLatest.Click += (_, _) => VersionCompareDialog.Show(
                TopLevel.GetTopLevel(this) as Window, versions[1].Content, versions[0].Content);
            versionCard.Children.Add(compareLatest);
        }
        _sidePanel.Children.Add(ArchiveUI.Card(versionCard, ArchiveUI.Raised));

        // 来路（R-007）
        var relations = await _model.LoadRelationsAsync(_draft.Id);
        var relationCard = new StackPanel { Spacing = 6 };
        relationCard.Children.Add(ArchiveUI.SectionTitle("来路"));
        if (relations.Count == 0)
        {
            relationCard.Children.Add(ArchiveUI.Muted("没有拆分/合并/衍生记录。", 12));
        }
        foreach (var relation in relations)
        {
            var otherId = relation.SourceDraftId == _draft.Id ? relation.TargetDraftId : relation.SourceDraftId;
            var otherTitle = _model.DraftTitle(otherId) ?? "来源已删除";
            var direction = relation.SourceDraftId == _draft.Id ? "→" : "←";
            var note = relation.Note is { Length: > 0 } ? $"\n{relation.Note}" : "";
            var row = new StackPanel { Spacing = 3 };
            row.Children.Add(ArchiveUI.Body($"{relation.Type.DisplayName()} {direction} 「{otherTitle}」{note}", ArchiveUI.TextBrush, 12.5));
            var editNote = ArchiveUI.SecondaryButton("说明…");
            editNote.Padding = new Thickness(6, 2);
            var r = relation;
            editNote.Click += async (_, _) =>
            {
                var noteText = await TextInputDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                    "关系说明", "为这条关系写一句说明（留空即移除）", r.Note ?? "");
                await _model.UpdateRelationNoteAsync(r.Id, string.IsNullOrWhiteSpace(noteText) ? null : noteText, _draft.Id);
                await LoadSidePanelAsync();
            };
            row.Children.Add(editNote);
            relationCard.Children.Add(row);
        }
        _sidePanel.Children.Add(ArchiveUI.Card(relationCard, ArchiveUI.Raised));
    }

    private async System.Threading.Tasks.Task ReloadSelfAsync()
    {
        await _model.ReloadAsync();
        await LoadSidePanelAsync();
    }

    private async System.Threading.Tasks.Task SplitAsync()
    {
        if (_draft.Content is null)
        {
            await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window, "拆分",
                "这份草稿没有可拆分的正文。", ("知道了", false));
            return;
        }
        var paragraphs = _draft.Content.Split("\n\n", StringSplitOptions.RemoveEmptyEntries)
            .Where(p => !string.IsNullOrWhiteSpace(p.Trim())).ToList();
        if (paragraphs.Count < 2)
        {
            await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window, "拆分",
                "草稿至少要有两个段落才能拆分（以空行分段）。", ("知道了", false));
            return;
        }
        var choice = await ChoiceDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window, "拆分段落",
            paragraphs.Select((p, i) => $"第 {i + 1} 段：{string.Concat(p.Take(40))}…").ToList(), -1);
        if (choice < 0) return;
        var piece = paragraphs[choice];
        var offset = _draft.Content.IndexOf(piece, StringComparison.Ordinal);
        var confirm = await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
            "拆分草稿", $"把选中的段落拆为新草稿？源草稿保持不变，双向可追溯。",
            ("取消", false), ("拆分", false));
        if (confirm == 1)
        {
            await _model.SplitDraftAsync(_draft, piece, Math.Max(0, offset));
        }
    }

    private async System.Threading.Tasks.Task DeleteAsync()
    {
        var impact = await _model.DeletionImpactAsync(_draft);
        var choice = await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
            "删除草稿", impact, ("取消", false), ("确认删除", true));
        if (choice == 1)
        {
            await _model.DeleteDraftAsync(_draft);
        }
    }
}

/// <summary>版本对比视图（R-006：LCS 行级差异，removed/added 清晰标注）。</summary>
public static class VersionCompareDialog
{
    public static void Show(Window? owner, string oldText, string newText)
    {
        if (owner is null) return;
        var dialog = new Window
        {
            Title = "版本对比（旧 → 新）",
            Width = 760,
            Height = 560,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = ArchiveUI.Canvas,
        };
        var panel = new StackPanel { Margin = new Thickness(14), Spacing = 8 };
        panel.Children.Add(ArchiveUI.Muted("红=旧版独有，绿=新版独有。恢复旧版会产生新版本，不抹掉历史。", 12));
        var diffPanel = new StackPanel { Spacing = 1 };
        foreach (var op in LineDiff.Diff(oldText, newText))
        {
            var (brush, prefix) = op.Kind switch
            {
                LineDiff.OpKind.Removed => (ArchiveUI.Danger, "− "),
                LineDiff.OpKind.Added => (ArchiveUI.Confirmed, "+ "),
                _ => (ArchiveUI.MutedText, "  "),
            };
            diffPanel.Children.Add(new TextBlock
            {
                Text = prefix + op.Text,
                FontSize = 12.5,
                Foreground = brush,
                FontFamily = new FontFamily("Consolas, Menlo, monospace"),
                TextWrapping = TextWrapping.Wrap,
            });
        }
        panel.Children.Add(new ScrollViewer { Content = diffPanel });
        var close = ArchiveUI.PrimaryButton("关闭");
        close.Click += (_, _) => dialog.Close();
        panel.Children.Add(close);
        dialog.Content = panel;
        dialog.Show(owner);
    }
}
