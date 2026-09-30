using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>新草稿全页（UI-04 / W-001）：只有正文即可保存；未保存返回需确认；失败保留输入。</summary>
public sealed class NewDraftPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly TextBox _titleBox;
    private readonly TextBox _contentBox;
    private readonly TextBlock _errorText;
    private bool _saved;

    public NewDraftPage(AppViewModel model)
    {
        _model = model;
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };

        var header = ArchiveUI.HStack(10);
        header.Margin = new Thickness(28, 22, 28, 10);
        var index = new TextBlock { Text = "✎", FontSize = 26, Foreground = ArchiveUI.Accent, VerticalAlignment = VerticalAlignment.Bottom };
        var title = new TextBlock { Text = "新草稿", FontSize = 30, FontWeight = FontWeight.SemiBold, Foreground = ArchiveUI.TextBrush, VerticalAlignment = VerticalAlignment.Bottom };
        var subtitle = new TextBlock { Text = "不完整也可以保存；标题可以稍后补", FontSize = 13, Foreground = ArchiveUI.MutedText, VerticalAlignment = VerticalAlignment.Bottom };
        header.Children.Add(index);
        header.Children.Add(title);
        header.Children.Add(subtitle);
        var spacer = new Border();
        Grid.SetColumn(spacer, 1);
        header.Children.Add(spacer);
        var cancelButton = ArchiveUI.SecondaryButton("返回");
        cancelButton.Click += async (_, _) => await ConfirmBackAsync();
        header.Children.Add(cancelButton);
        root.Children.Add(header);

        var editor = new StackPanel { Spacing = 10, Margin = new Thickness(28, 8, 28, 8) };
        _titleBox = new TextBox
        {
            Watermark = "标题（可空）",
            FontSize = 20,
            FontWeight = FontWeight.SemiBold,
        };
        _contentBox = new TextBox
        {
            Watermark = "正文：一句话、半篇文章、Prompt、笔记都可以。",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 15,
            MinHeight = 380,
            MaxWidth = 720,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        _errorText = new TextBlock
        {
            FontSize = 12.5,
            Foreground = ArchiveUI.Danger,
            TextWrapping = TextWrapping.Wrap,
            IsVisible = false,
        };
        editor.Children.Add(_titleBox);
        editor.Children.Add(_contentBox);
        editor.Children.Add(_errorText);
        var editorScroll = new ScrollViewer { Content = editor };
        Grid.SetRow(editorScroll, 1);
        root.Children.Add(editorScroll);

        var footer = ArchiveUI.HStack(10);
        footer.Margin = new Thickness(28, 8, 28, 18);
        var saveButton = ArchiveUI.PrimaryButton("保存到草稿箱");
        saveButton.Click += async (_, _) => await SaveAsync();
        footer.Children.Add(saveButton);
        footer.Children.Add(ArchiveUI.Muted("保存后自动留版本：静默 60 秒或离开页面时结算。"));
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);

        Content = root;
        _contentBox.Focus();
    }

    private async System.Threading.Tasks.Task SaveAsync()
    {
        var content = _contentBox.Text ?? "";
        if (string.IsNullOrWhiteSpace(content) && string.IsNullOrWhiteSpace(_titleBox.Text))
        {
            ShowError("标题和正文都为空：先写点什么再保存。");
            return;
        }
        var ok = await _model.CreateDraftAsync(_titleBox.Text ?? "", content);
        if (ok)
        {
            _saved = true;
        }
        else
        {
            ShowError(_model.NewDraftError ?? "保存失败，输入已保留。");
        }
    }

    private async System.Threading.Tasks.Task ConfirmBackAsync()
    {
        var hasInput = !string.IsNullOrWhiteSpace(_contentBox.Text) || !string.IsNullOrWhiteSpace(_titleBox.Text);
        if (hasInput && !_saved)
        {
            var choice = await ConfirmDialog.ShowAsync(TopLevel.GetTopLevel(this) as Window,
                "返回", "有未保存的内容。要继续编辑还是丢弃？",
                ("继续编辑", false), ("丢弃未保存内容", true));
            if (choice != 1) return;
        }
        _model.ShowNewDraftPage = false;
        _model.NewDraftError = null;
    }

    private void ShowError(string message)
    {
        _errorText.Text = message;
        _errorText.IsVisible = true;
    }
}

/// <summary>简单确认对话框：返回选中按钮序号（取消=-1）。</summary>
public static class ConfirmDialog
{
    public static async System.Threading.Tasks.Task<int> ShowAsync(Window? owner,
        string title, string message, params (string Label, bool Destructive)[] buttons)
    {
        if (owner is null) return -1;
        var tcs = new System.Threading.Tasks.TaskCompletionSource<int>();
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
        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 14 };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeight.SemiBold, Foreground = ArchiveUI.TextBrush });
        panel.Children.Add(ArchiveUI.Body(message, ArchiveUI.TextBrush, 13.5));
        var row = ArchiveUI.HStack(8);
        row.HorizontalAlignment = HorizontalAlignment.Right;
        for (int i = 0; i < buttons.Length; i++)
        {
            var (label, destructive) = buttons[i];
            var index = i;
            var button = destructive ? ArchiveUI.SecondaryButton(label) : ArchiveUI.PrimaryButton(label);
            if (destructive) button.Foreground = ArchiveUI.Danger;
            button.Click += (_, _) => { tcs.TrySetResult(index); dialog.Close(); };
            row.Children.Add(button);
        }
        panel.Children.Add(row);
        dialog.Content = panel;
        await dialog.ShowDialog(owner);
        return await tcs.Task;
    }
}
