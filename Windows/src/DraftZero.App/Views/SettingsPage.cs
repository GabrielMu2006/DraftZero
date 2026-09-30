using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>06 设置（W-008/W-009/W-011）："本机归类"与"可选 DeepSeek"分开；迁移导入；数据位置。</summary>
public sealed class SettingsPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly TextBox _apiKeyBox = new() { PasswordChar = '•', Watermark = "sk-…" };
    private readonly StackPanel _semanticPanel = new() { Spacing = 8 };
    private readonly TextBlock _migrationText = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Foreground = ArchiveUI.MutedText, IsVisible = false };
    private readonly TextBlock _remoteStatusText = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Foreground = ArchiveUI.Accent, IsVisible = false };
    private readonly Button _remoteToggleButton = new() { Padding = new Thickness(12, 5) };

    public SettingsPage(AppViewModel model)
    {
        _model = model;
        var scroll = new ScrollViewer { Padding = new Thickness(0, 0, 0, 24) };
        var panel = new StackPanel { Spacing = 14 };

        panel.Children.Add(ArchiveUI.PageHeader("06", "设置", "本机优先；远程分析默认关闭"));
        panel.Children.Add(BuildSemanticCard());
        panel.Children.Add(BuildMigrationCard());
        panel.Children.Add(BuildRemoteCard());
        panel.Children.Add(BuildAboutCard());
        scroll.Content = panel;
        Content = scroll;
        RefreshSemantic();
        RefreshRemote();
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppViewModel.SemanticState) or nameof(AppViewModel.ClueReport)) RefreshSemantic();
            if (e.PropertyName is nameof(AppViewModel.RemoteStatus) or nameof(AppViewModel.RemoteEnabled) or nameof(AppViewModel.RemoteHasKey)) RefreshRemote();
            if (e.PropertyName is nameof(AppViewModel.MigrationMessage)) RefreshMigration();
        };
    }

    private Control BuildSemanticCard()
    {
        var card = new StackPanel { Spacing = 10 };
        card.Children.Add(ArchiveUI.SectionTitle("本机归类"));
        card.Children.Add(_semanticPanel);
        var rebuild = ArchiveUI.SecondaryButton("重建索引");
        rebuild.Click += async (_, _) => await _model.RebuildSemanticIndexAsync();
        card.Children.Add(rebuild);
        card.Children.Add(ArchiveUI.Muted(
            "本机语义模型（multilingual-e5-small，随应用分发）离线运行，模型与索引不出本机。索引损坏时可重建，不影响已确认的项目归属。", 12));
        return ArchiveUI.Card(card, ArchiveUI.Surface);
    }

    private void RefreshSemantic()
    {
        _semanticPanel.Children.Clear();
        switch (_model.SemanticState)
        {
            case AppViewModel.SemanticUiState.Idle:
            case AppViewModel.SemanticUiState.Indexing:
                _semanticPanel.Children.Add(ArchiveUI.Body("索引中…", ArchiveUI.MutedText, 13));
                break;
            case AppViewModel.SemanticUiState.Ready:
                _semanticPanel.Children.Add(ArchiveUI.Body(
                    $"语义模型正常 · 已索引 {_model.ClueReport?.IndexedDrafts ?? 0} 份草稿", ArchiveUI.Confirmed, 13));
                break;
            case AppViewModel.SemanticUiState.Degraded:
                _semanticPanel.Children.Add(ArchiveUI.Body(
                    _model.SemanticStateDetail ?? "语义线索暂不可用，当前只显示关键词线索", ArchiveUI.Danger, 13));
                break;
        }
    }

    private Control BuildMigrationCard()
    {
        var card = new StackPanel { Spacing = 10 };
        card.Children.Add(ArchiveUI.SectionTitle("从 Mac 导入工作区（一次性）"));
        card.Children.Add(ArchiveUI.Muted(
            "导入 Mac 版「设置 → 迁移到 Windows」导出的 .dzarchive 档案。仅允许导入到**空工作区**（当前工作区有内容时请先备份或另建位置）；导入是复制，之后两端不会同步。档案包含草稿正文与 PDF，不会导入 DeepSeek Key（需重新填写）。", 12));
        var import = ArchiveUI.PrimaryButton("导入 Mac 工作区档案…");
        import.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            var file = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择 .dzarchive 档案",
                AllowMultiple = false,
            });
            if (file.Count == 0) return;
            if (!_model.CanImportFromMac)
            {
                _migrationText.Text = "当前工作区已有内容。迁移仅支持导入到空工作区；请先备份或另建空工作区（不做自动合并）。";
                _migrationText.Foreground = ArchiveUI.Danger;
                _migrationText.IsVisible = true;
                return;
            }
            await _model.ImportMacArchiveAsync(file[0].Path.LocalPath);
        };
        card.Children.Add(import);
        card.Children.Add(_migrationText);
        return ArchiveUI.Card(card, ArchiveUI.Surface);
    }

    private void RefreshMigration()
    {
        if (_model.MigrationMessage is { } message)
        {
            _migrationText.Text = message;
            _migrationText.Foreground = message.Contains("失败") ? ArchiveUI.Danger : ArchiveUI.Confirmed;
            _migrationText.IsVisible = true;
        }
    }

    private Control BuildRemoteCard()
    {
        var card = new StackPanel { Spacing = 10 };
        card.Children.Add(ArchiveUI.SectionTitle("DeepSeek 分析（可选）"));

        _remoteToggleButton.Click += async (_, _) =>
        {
            if (_model.RemoteEnabled)
            {
                _model.DisableRemoteAnalysis();
                RefreshRemote();
            }
            else
            {
                await EnableAsync();
            }
        };
        card.Children.Add(_remoteToggleButton);

        card.Children.Add(ArchiveUI.Muted(
            "启用后，新加入草稿的可读取文本（标题与正文节选，不含文件路径、不上传原始文件）会发送至 DeepSeek 分析。可能产生由你的 DeepSeek 账户支付的费用。", 12));

        var keyRow = ArchiveUI.HStack(8);
        keyRow.Children.Add(_apiKeyBox);
        var saveKey = ArchiveUI.SecondaryButton("保存 Key");
        saveKey.Click += async (_, _) => await EnableAsync();
        keyRow.Children.Add(saveKey);
        var removeKey = ArchiveUI.SecondaryButton("移除 Key");
        removeKey.Foreground = ArchiveUI.Danger;
        removeKey.Click += (_, _) => { _model.RemoveRemoteKey(); RefreshRemote(); };
        keyRow.Children.Add(removeKey);
        card.Children.Add(keyRow);
        card.Children.Add(ArchiveUI.Muted(
            "Key 保存在 Windows 用户级受保护存储（DPAPI），不写入草稿、迁移档案或普通日志。", 11.5));

        card.Children.Add(_remoteStatusText);

        var analyzeAll = ArchiveUI.SecondaryButton("分析现有草稿");
        analyzeAll.Click += async (_, _) => await _model.AnalyzeAllDraftsRemotelyAsync();
        card.Children.Add(analyzeAll);
        card.Children.Add(ArchiveUI.Muted(
            "远程建议仅在引用了草稿原文片段时才会展示，始终标注「远程补充 · DeepSeek」，只是建议——不自动确认任何归类。关闭或失败时本机归类照常可用。", 12));
        return ArchiveUI.Card(card, ArchiveUI.Surface);
    }

    private async System.Threading.Tasks.Task EnableAsync()
    {
        await _model.EnableRemoteAnalysisAsync(_apiKeyBox.Text ?? "");
        RefreshRemote();
    }

    private void RefreshRemote()
    {
        _remoteToggleButton.Content = _model.RemoteEnabled
            ? "远程分析：已开启（点击关闭）"
            : "远程分析：默认关闭（点击开启）";
        _remoteStatusText.Text = _model.RemoteStatus
            ?? (_model.RemoteEnabled ? "已开启：新加入的草稿将自动分析" : "默认关闭：不发送任何草稿内容。");
        _remoteStatusText.Foreground = _model.RemoteEnabled ? ArchiveUI.Confirmed : ArchiveUI.MutedText;
        _remoteStatusText.IsVisible = true;
        _apiKeyBox.Watermark = _model.RemoteHasKey ? "已保存（输入新 Key 可替换）" : "sk-…";
    }

    private Control BuildAboutCard()
    {
        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(ArchiveUI.SectionTitle("关于与数据"));
        card.Children.Add(ArchiveUI.Body("Draft Zero V0.2.0（Windows 预览版）", ArchiveUI.TextBrush, 13.5));
        card.Children.Add(ArchiveUI.Muted($"数据目录：{_model.WorkspacePath}", 12));
        card.Children.Add(ArchiveUI.Muted("无账号、无云端、无遥测；核心归类完全离线。", 12));
        return ArchiveUI.Card(card, ArchiveUI.Surface);
    }
}
