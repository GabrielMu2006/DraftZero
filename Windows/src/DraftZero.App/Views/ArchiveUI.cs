using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>「索引档案」共享组件（对齐 UI-REDESIGN-PLAN §3.1 组件标准化）。</summary>
public static class ArchiveUI
{
    public static IBrush Canvas => AppBrush("CanvasBrush");
    public static IBrush Surface => AppBrush("SurfaceBrush");
    public static IBrush Rail => AppBrush("RailBrush");
    public static IBrush Raised => AppBrush("RaisedBrush");
    public static IBrush Selected => AppBrush("SelectedBrush");
    public static IBrush TextBrush => AppBrush("TextBrush");
    public static IBrush MutedText => AppBrush("MutedTextBrush");
    public static IBrush Rule => AppBrush("RuleBrush");
    public static IBrush Accent => AppBrush("AccentBrush");
    public static IBrush Confirmed => AppBrush("ConfirmedBrush");
    public static IBrush RemoteBrush => AppBrush("RemoteBrush");
    public static IBrush Danger => AppBrush("DangerBrush");

    private static IBrush AppBrush(string key) =>
        (Application.Current!.Resources[key] as IBrush)!;

    /// <summary>页面头：编号 + 大标题 + 副标题。</summary>
    public static Control PageHeader(string index, string title, string subtitle)
    {
        var panel = new StackPanel { Margin = new Thickness(28, 22, 28, 14), Spacing = 4 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        titleRow.Children.Add(new TextBlock
        {
            Text = index,
            FontSize = 30,
            Foreground = Accent,
            VerticalAlignment = VerticalAlignment.Bottom,
        });
        titleRow.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 31,
            FontWeight = FontWeight.SemiBold,
            Foreground = TextBrush,
            VerticalAlignment = VerticalAlignment.Bottom,
        });
        panel.Children.Add(titleRow);
        panel.Children.Add(new TextBlock
        {
            Text = subtitle,
            FontSize = 13,
            Foreground = MutedText,
        });
        return panel;
    }

    /// <summary>区标题（18–21 字号衬线感）。</summary>
    public static TextBlock SectionTitle(string text) => new()
    {
        Text = text,
        FontSize = 18,
        FontWeight = FontWeight.SemiBold,
        Foreground = TextBrush,
        Margin = new Thickness(0, 4, 0, 4),
    };

    public static TextBlock Body(string text, IBrush? brush = null, double size = 14.5) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = brush ?? TextBrush,
        TextWrapping = TextWrapping.Wrap,
        LineHeight = size * 1.55,
    };

    public static TextBlock Muted(string text, double size = 12) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = MutedText,
        TextWrapping = TextWrapping.Wrap,
        LineHeight = size * 1.5,
    };

    /// <summary>纸面卡片。</summary>
    public static Border Card(Control content, IBrush? background = null) => new()
    {
        Background = background ?? Surface,
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(14),
        Child = content,
    };

    /// <summary>状态章（文字+颜色，不依赖纯色传达）。</summary>
    public static Border StatusChip(string text, IBrush color)
    {
        var chip = new Border
        {
            Background = Surface,
            BorderBrush = color,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(9, 2.5),
            Child = new TextBlock { Text = text, FontSize = 11.5, Foreground = color },
            VerticalAlignment = VerticalAlignment.Center,
        };
        return chip;
    }

    public static Button PrimaryButton(string text) => new()
    {
        Content = text,
        Padding = new Thickness(14, 6),
        FontWeight = FontWeight.SemiBold,
    };

    public static Button SecondaryButton(string text) => new()
    {
        Content = text,
        Padding = new Thickness(12, 5),
    };

    /// <summary>空状态：说明 + 强入口（UI-03：两个强入口）。</summary>
    public static Control EmptyState(string message, params Control[] actions)
    {
        var panel = new StackPanel
        {
            Spacing = 12,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 460,
        };
        panel.Children.Add(new TextBlock
        {
            Text = message,
            FontSize = 15.5,
            Foreground = MutedText,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            LineHeight = 24,
        });
        if (actions.Length > 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var action in actions) row.Children.Add(action);
            panel.Children.Add(row);
        }
        return panel;
    }

    /// <summary>错误/降级横幅（R-012：可识别状态，不冒充正常）。</summary>
    public static Border NoticeBar(string text, IBrush color) => new()
    {
        Background = Surface,
        BorderBrush = color,
        BorderThickness = new Thickness(1, 0, 0, 0),
        CornerRadius = new CornerRadius(4),
        Padding = new Thickness(12, 8),
        Margin = new Thickness(28, 0, 28, 10),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 12.5,
            Foreground = TextBrush,
            TextWrapping = TextWrapping.Wrap,
        },
    };

    public static Separator RuleLine() => new() { Background = Rule, Margin = new Thickness(28, 0, 28, 0), Height = 1 };

    public static ScrollViewer Scroll(Control content) => new()
    {
        Content = content,
    };

    public static StackPanel VStack(double spacing = 10, Thickness? margin = null) => new()
    {
        Spacing = spacing,
        Margin = margin ?? new Thickness(28, 0, 28, 20),
    };

    public static StackPanel HStack(double spacing = 8) => new() { Orientation = Orientation.Horizontal, Spacing = spacing };

    /// <summary>来源类型中文名。</summary>
    public static string SourceName(SourceType type) => type.DisplayName();

    /// <summary>相对时间展示。</summary>
    public static string Relative(DateTime utc)
    {
        var local = utc.ToLocalTime();
        var delta = DateTime.Now - local;
        if (delta.TotalMinutes < 1) return "刚刚";
        if (delta.TotalHours < 1) return $"{(int)delta.TotalMinutes} 分钟前";
        if (delta.TotalDays < 1) return $"{(int)delta.TotalHours} 小时前";
        if (delta.TotalDays < 30) return $"{(int)delta.TotalDays} 天前";
        return local.ToString("yyyy-MM-dd");
    }
}
