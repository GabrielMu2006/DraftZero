using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DraftZero.Core;

namespace DraftZero.App.Views;

/// <summary>
/// 02 线索台（UI-05 / W-004）：队列 + 文档对照两栏；证据按需展开；
/// 接受/拒绝/暂缓可见；本机、降级、索引中、空结果、远程补充各有不同状态。
/// </summary>
public sealed class ClueDeskPage : UserControl
{
    private readonly AppViewModel _model;
    private readonly StackPanel _queuePanel = new() { Spacing = 6 };
    private readonly StackPanel _comparePanel = new() { Spacing = 10 };
    private readonly StackPanel _bannerHost = new() { Margin = new Thickness(28, 0, 28, 10) };
    private CandidatePair? _selectedPair;
    private string _queueMode = "lead";

    public ClueDeskPage(AppViewModel model)
    {
        _model = model;
        var root = new Grid
        {
            RowDefinitions = new RowDefinitions("Auto,Auto,*"),
            ColumnDefinitions = new ColumnDefinitions("280,*"),
        };

        var header = new StackPanel();
        header.Children.Add(ArchiveUI.PageHeader("02", "线索台", "本机语义线索与人工裁决；建议不自动改变归属"));
        Grid.SetColumnSpan(header, 2);
        root.Children.Add(header);

        // 状态行（R-004 降级要求）；缓存页随数据变化自刷新
        _bannerHost.Children.Add(StateBanner());
        Grid.SetColumnSpan(_bannerHost, 2);
        Grid.SetRow(_bannerHost, 1);
        root.Children.Add(_bannerHost);

        // 队列列
        var queueScroll = new ScrollViewer { Content = _queuePanel, Padding = new Thickness(28, 0, 10, 20) };
        Grid.SetColumn(queueScroll, 0);
        Grid.SetRow(queueScroll, 2);
        root.Children.Add(queueScroll);

        // 对照列
        var compareScroll = new ScrollViewer { Content = _comparePanel, Padding = new Thickness(14, 0, 28, 20) };
        Grid.SetColumn(compareScroll, 1);
        Grid.SetRow(compareScroll, 2);
        root.Children.Add(compareScroll);

        Content = root;
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppViewModel.LeadPairs) or nameof(AppViewModel.DuplicatePairs)
                or nameof(AppViewModel.DeferredLeads) or nameof(AppViewModel.RejectedLeads)
                or nameof(AppViewModel.RemoteSuggestions) or nameof(AppViewModel.SemanticState)
                or nameof(AppViewModel.SemanticStateDetail))
            {
                _bannerHost.Children.Clear();
                _bannerHost.Children.Add(StateBanner());
                RefreshQueues();
            }
            if (e.PropertyName == nameof(AppViewModel.Drafts))
            {
                // 对齐 Mac「进入线索台时刷新」：草稿集变化即重跑本机增量索引
                // （RefreshSemanticAsync 自带索引中防并发）。
                _ = _model.RefreshSemanticAsync();
            }
        };
        _ = _model.RefreshSemanticAsync();
        RefreshQueues();
        SelectFirst();
    }

    private Control StateBanner() => _model.SemanticState switch
    {
        AppViewModel.SemanticUiState.Indexing => ArchiveUI.NoticeBar("正在本机建立语义索引…", ArchiveUI.Accent),
        AppViewModel.SemanticUiState.Degraded => ArchiveUI.NoticeBar(
            _model.SemanticStateDetail ?? "语义线索暂不可用，当前只显示关键词线索", ArchiveUI.Danger),
        _ when _model.PendingClueCount == 0 && _model.SemanticState == AppViewModel.SemanticUiState.Ready =>
            ArchiveUI.NoticeBar("暂未发现关联。可以先手动创建项目，或继续导入素材。", ArchiveUI.Confirmed),
        _ => ArchiveUI.NoticeBar(
            $"本机语义模型正常 · 待审线索 {_model.LeadPairs.Count} · 可能重复 {_model.DuplicatePairs.Count}" +
            (_model.RemoteSuggestions.Count > 0 ? $" · 远程补充 {_model.RemoteSuggestions.Count}" : ""),
            ArchiveUI.Confirmed),
    };

    private void RefreshQueues()
    {
        _queuePanel.Children.Clear();

        void AddSection(string title, IReadOnlyList<CandidatePair> pairs, string mode)
        {
            _queuePanel.Children.Add(new TextBlock
            {
                Text = $"{title}（{pairs.Count}）",
                FontSize = 13.5,
                FontWeight = FontWeight.SemiBold,
                Foreground = ArchiveUI.TextBrush,
                Margin = new Thickness(0, 10, 0, 2),
            });
            foreach (var pair in pairs)
            {
                var p = pair;
                var otherA = _model.DraftTitle(pair.DraftA) ?? "(已删除)";
                var otherB = _model.DraftTitle(pair.DraftB) ?? "(已删除)";
                var selected = pair.Id == _selectedPair?.Id;
                var item = ArchiveUI.Card(new StackPanel
                {
                    Spacing = 3,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = $"{otherA} × {otherB}",
                            FontSize = 12.5,
                            Foreground = ArchiveUI.TextBrush,
                            TextWrapping = TextWrapping.Wrap,
                            MaxHeight = 40,
                        },
                        new TextBlock
                        {
                            Text = pair.LastDecision is { } decision ? $"上次裁决：{decision}" : "待审",
                            FontSize = 10.5,
                            Foreground = ArchiveUI.MutedText,
                        },
                    },
                }, selected ? ArchiveUI.Selected : ArchiveUI.Raised);
                item.Tapped += (_, _) =>
                {
                    _selectedPair = p;
                    _queueMode = mode;
                    RefreshQueues();
                    ShowComparison(p);
                };
                _queuePanel.Children.Add(item);
            }
        }

        AddSection("待审线索", _model.LeadPairs, "lead");
        AddSection("可能重复", _model.DuplicatePairs, "duplicate");
        AddSection("稍后处理", _model.DeferredLeads, "deferred");
        AddSection("已拒绝（可重新分析）", _model.RejectedLeads, "rejected");

        // 远程建议（始终标明来源）
        if (_model.RemoteSuggestions.Count > 0)
        {
            _queuePanel.Children.Add(new TextBlock
            {
                Text = $"远程补充 · DeepSeek（{_model.RemoteSuggestions.Count}）",
                FontSize = 13.5,
                FontWeight = FontWeight.SemiBold,
                Foreground = ArchiveUI.RemoteBrush,
                Margin = new Thickness(0, 10, 0, 2),
            });
            foreach (var suggestion in _model.RemoteSuggestions)
            {
                var s = suggestion;
                var names = suggestion.DraftIds.Select(id => _model.DraftTitle(id) ?? "(已删除)").ToList();
                var item = ArchiveUI.Card(new StackPanel
                {
                    Spacing = 3,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = string.Join(" × ", names.Take(4)) + (names.Count > 4 ? " 等" : ""),
                            FontSize = 12.5,
                            Foreground = ArchiveUI.TextBrush,
                            TextWrapping = TextWrapping.Wrap,
                        },
                        new TextBlock
                        {
                            Text = "远程补充 · DeepSeek（仅建议，不自动归类）",
                            FontSize = 10.5,
                            Foreground = ArchiveUI.RemoteBrush,
                        },
                    },
                }, ArchiveUI.Raised);
                item.Tapped += (_, _) => ShowRemoteSuggestion(s);
                _queuePanel.Children.Add(item);
            }
        }
    }

    private void SelectFirst()
    {
        if (_model.LeadPairs.Count > 0) { _selectedPair = _model.LeadPairs[0]; _queueMode = "lead"; }
        else if (_model.DuplicatePairs.Count > 0) { _selectedPair = _model.DuplicatePairs[0]; _queueMode = "duplicate"; }
        if (_selectedPair is not null) ShowComparison(_selectedPair);
        else ShowEmptyComparison();
    }

    private void ShowEmptyComparison()
    {
        _comparePanel.Children.Clear();
        _comparePanel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState(
            _model.SemanticState == AppViewModel.SemanticUiState.Degraded
                ? "语义线索暂不可用（见左侧提示），可先手动创建项目。"
                : "暂未发现关联。继续导入素材或编辑草稿后，本机线索会自动更新。")));
    }

    /// <summary>两栏对照 + 证据（R-004"给出证据"）。</summary>
    private void ShowComparison(CandidatePair pair)
    {
        _comparePanel.Children.Clear();
        var draftA = _model.Drafts.FirstOrDefault(d => d.Id == pair.DraftA);
        var draftB = _model.Drafts.FirstOrDefault(d => d.Id == pair.DraftB);

        var evidence = pair.EvidenceDecoded();
        _comparePanel.Children.Add(BuildPairHeader(pair, draftA, draftB));

        if (evidence is not null)
        {
            var terms = evidence.CommonTerms.Count > 0
                ? "共同术语：" + string.Join("、", evidence.CommonTerms)
                : "内容含义相近（本机语义，无可引用的共同关键词）";
            _comparePanel.Children.Add(ArchiveUI.Card(new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    ArchiveUI.SectionTitle("依据"),
                    ArchiveUI.Body(terms, ArchiveUI.TextBrush, 13),
                    ArchiveUI.Muted($"语义相似度分量 {evidence.SemanticScore:0.000} · 未校准百分比不对外展示"),
                    EvidenceSnippet("甲 · " + (evidence.A.Heading ?? "片段"), evidence.A.Text),
                    EvidenceSnippet("乙 · " + (evidence.B.Heading ?? "片段"), evidence.B.Text),
                },
            }, ArchiveUI.Raised));
        }

        // 双方摘录
        _comparePanel.Children.Add(BuildExcerpt("甲", draftA));
        _comparePanel.Children.Add(BuildExcerpt("乙", draftB));

        // 裁决按钮
        var actions = ArchiveUI.HStack(8);
        var accept = ArchiveUI.PrimaryButton("归入项目…");
        accept.Click += (_, _) => JoinProjectSheet.ShowForPair(TopLevel.GetTopLevel(this) as MainWindow, _model, pair);
        actions.Children.Add(accept);
        var reject = ArchiveUI.SecondaryButton("标记不相关");
        reject.Click += async (_, _) => { await _model.RejectPairAsync(pair); _selectedPair = null; RefreshQueues(); ShowEmptyComparison(); };
        actions.Children.Add(reject);
        var defer = ArchiveUI.SecondaryButton("暂缓");
        defer.Click += async (_, _) => { await _model.DeferPairAsync(pair); RefreshQueues(); };
        actions.Children.Add(defer);
        if (pair.Status is CandidateStatus.Rejected or CandidateStatus.Deferred)
        {
            var reanalyze = ArchiveUI.SecondaryButton("重新分析");
            reanalyze.Click += async (_, _) => { await _model.ReanalyzePairAsync(pair); RefreshQueues(); };
            actions.Children.Add(reanalyze);
        }
        var actionCard = ArchiveUI.Card(actions, ArchiveUI.Surface);
        _comparePanel.Children.Add(actionCard);
    }

    private Control BuildPairHeader(CandidatePair pair, Draft? draftA, Draft? draftB)
    {
        var kindName = pair.Kind == CandidateKind.Duplicate ? "可能重复" : "项目线索";
        var panel = new StackPanel { Spacing = 4 };
        var row = ArchiveUI.HStack(10);
        row.Children.Add(new TextBlock
        {
            Text = kindName,
            FontSize = 20,
            FontWeight = FontWeight.SemiBold,
            Foreground = pair.Kind == CandidateKind.Duplicate ? ArchiveUI.Danger : ArchiveUI.Accent,
        });
        row.Children.Add(ArchiveUI.StatusChip("本机线索", ArchiveUI.MutedText));
        panel.Children.Add(row);
        panel.Children.Add(ArchiveUI.Body(
            $"{(draftA?.Title ?? "(已删除)")} × {(draftB?.Title ?? "(已删除)")}", ArchiveUI.TextBrush, 14));
        return panel;
    }

    private Control EvidenceSnippet(string label, string text) => new Border
    {
        Background = ArchiveUI.Surface,
        CornerRadius = new Avalonia.CornerRadius(8),
        Padding = new Thickness(10, 8),
        Child = new StackPanel
        {
            Spacing = 3,
            Children =
            {
                ArchiveUI.Muted(label, 11),
                ArchiveUI.Body(text, ArchiveUI.TextBrush, 12.5),
            },
        },
    };

    private Control BuildExcerpt(string side, Draft? draft)
    {
        if (draft is null)
        {
            return ArchiveUI.Card(ArchiveUI.Muted($"{side}：来源已删除。"));
        }
        var text = draft.Content ?? "（无可用于关联的文字）";
        var preview = text.Length > 1200 ? text[..1200] + "…" : text;
        return ArchiveUI.Card(new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        ArchiveUI.SectionTitle(side),
                        ArchiveUI.StatusChip(ArchiveUI.SourceName(draft.SourceType), ArchiveUI.MutedText),
                    },
                },
                ArchiveUI.Body(draft.Title, ArchiveUI.TextBrush, 14.5),
                ArchiveUI.Body(preview, ArchiveUI.TextBrush, 13),
                ArchiveUI.Muted(draft.SourceLocation is { } loc ? $"来源：{loc}" : "应用内新建"),
            },
        }, ArchiveUI.Raised);
    }

    /// <summary>远程建议详情（R-010：引用已通过原文校验；仍需人工确认）。</summary>
    private void ShowRemoteSuggestion(RemoteSuggestion suggestion)
    {
        _comparePanel.Children.Clear();
        var panel = new StackPanel { Spacing = 10 };
        var row = ArchiveUI.HStack(10);
        row.Children.Add(new TextBlock
        {
            Text = "远程补充 · DeepSeek",
            FontSize = 20,
            FontWeight = FontWeight.SemiBold,
            Foreground = ArchiveUI.RemoteBrush,
        });
        panel.Children.Add(row);
        panel.Children.Add(ArchiveUI.Muted("远程建议仅供参考，不自动确认归类；引用已按草稿原文校验。"));
        if (!string.IsNullOrEmpty(suggestion.Notice))
        {
            panel.Children.Add(ArchiveUI.NoticeBar(suggestion.Notice, ArchiveUI.RemoteBrush));
        }
        if (!string.IsNullOrEmpty(suggestion.Explanation))
        {
            panel.Children.Add(ArchiveUI.Card(ArchiveUI.Body(suggestion.Explanation!, ArchiveUI.TextBrush, 13.5), ArchiveUI.Raised));
        }
        foreach (var citation in suggestion.Citations)
        {
            var draft = _model.Drafts.FirstOrDefault(d => d.Id == citation.DraftId);
            panel.Children.Add(EvidenceSnippet(draft?.Title ?? "(已删除)", citation.Quote));
        }
        var actions = ArchiveUI.HStack(8);
        var accept = ArchiveUI.PrimaryButton("归入项目…");
        accept.Click += (_, _) => JoinProjectSheet.ShowForSuggestion(TopLevel.GetTopLevel(this) as MainWindow, _model, suggestion);
        actions.Children.Add(accept);
        var dismiss = ArchiveUI.SecondaryButton("忽略此建议");
        dismiss.Click += async (_, _) =>
        {
            await _model.DismissRemoteSuggestionAsync(suggestion);
            _comparePanel.Children.Clear();
            _comparePanel.Children.Add(ArchiveUI.Card(ArchiveUI.EmptyState("已忽略该建议。")));
            RefreshQueues();
        };
        actions.Children.Add(dismiss);
        panel.Children.Add(actions);
        _comparePanel.Children.Add(panel);
    }
}
