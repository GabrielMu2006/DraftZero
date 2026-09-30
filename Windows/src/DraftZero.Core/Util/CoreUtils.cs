namespace DraftZero.Core;

/// <summary>
/// 行级文本差异（版本对比，R-006）。LCS 动态规划；超长文本退化为整段替换，
/// 提示用户用拆分查看局部。对齐 Mac LineDiff.swift（maxDiffLines=2000，UInt16 表）。
/// </summary>
public static class LineDiff
{
    public enum OpKind { Same, Added, Removed }

    public record Op(OpKind Kind, string Text);

    internal const int MaxDiffLines = 2000;

    public static List<Op> Diff(string oldText, string newText)
    {
        var oldLines = oldText.Split(["\r\n", "\n", "\r"], StringSplitOptions.None);
        var newLines = newText.Split(["\r\n", "\n", "\r"], StringSplitOptions.None);
        var capped = oldLines.Length > MaxDiffLines || newLines.Length > MaxDiffLines;
        if (capped)
        {
            // 超长降级：不丢内容，只标明整体替换。
            var degraded = new List<Op>(oldLines.Length + newLines.Length);
            degraded.AddRange(oldLines.Select(l => new Op(OpKind.Removed, l)));
            degraded.AddRange(newLines.Select(l => new Op(OpKind.Added, l)));
            return degraded;
        }

        int n = oldLines.Length, m = newLines.Length;
        // LCS 长度表（UInt16 足够，2000×2000 ≈ 8MB）。
        var table = new ushort[n + 1][];
        for (int i = 0; i <= n; i++) table[i] = new ushort[m + 1];
        for (int i = n - 1; i >= 0; i--)
        {
            for (int j = m - 1; j >= 0; j--)
            {
                table[i][j] = (ushort)(oldLines[i] == newLines[j]
                    ? table[i + 1][j + 1] + 1
                    : Math.Max(table[i + 1][j], table[i][j + 1]));
            }
        }

        var ops = new List<Op>(n + m);
        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (oldLines[x] == newLines[y])
            {
                ops.Add(new Op(OpKind.Same, oldLines[x])); x++; y++;
            }
            else if (table[x + 1][y] >= table[x][y + 1])
            {
                ops.Add(new Op(OpKind.Removed, oldLines[x])); x++;
            }
            else
            {
                ops.Add(new Op(OpKind.Added, newLines[y])); y++;
            }
        }
        while (x < n) { ops.Add(new Op(OpKind.Removed, oldLines[x])); x++; }
        while (y < m) { ops.Add(new Op(OpKind.Added, newLines[y])); y++; }
        return ops;
    }

    public static bool HasChanges(IReadOnlyList<Op> ops) =>
        ops.Any(op => op.Kind != OpKind.Same);
}

/// <summary>
/// 自动版本记录器（R-006）：连续停止输入 60 秒、离开草稿或关闭窗口时，
/// 若正文相对上一版本有变化则生成版本；连续输入不逐字符建版本。
/// 时间间隔与时钟可注入，便于测试。对齐 Mac AutoVersioner.swift。
/// </summary>
public sealed class AutoVersioner
{
    public delegate Task PersistDelegate(Guid draftId, string content);

    private readonly TimeSpan _idleInterval;
    private readonly PersistDelegate _persist;
    private readonly Dictionary<Guid, CancellationTokenSource> _scheduled = new();
    private readonly Dictionary<Guid, string> _pending = new();
    private readonly object _gate = new();
    private readonly TimeProvider _clock;

    public AutoVersioner(PersistDelegate persist, TimeSpan? idleInterval = null, TimeProvider? clock = null)
    {
        _persist = persist;
        _idleInterval = idleInterval ?? TimeSpan.FromSeconds(60);
        _clock = clock ?? TimeProvider.System;
    }

    /// <summary>每次正文变化调用；重置该草稿的静默计时。</summary>
    public void ContentChanged(Guid draftId, string text)
    {
        Task task;
        lock (_gate)
        {
            _pending[draftId] = text;
            if (_scheduled.Remove(draftId, out var old))
            {
                old.Cancel();
                old.Dispose();
            }
            var cts = new CancellationTokenSource();
            _scheduled[draftId] = cts;
            task = Task.Delay(_idleInterval, _clock, cts.Token).ContinueWith(async _ =>
            {
                if (cts.IsCancellationRequested) return;
                await CommitAsync(draftId).ConfigureAwait(false);
            }).Unwrap();
        }
        _ = task;
    }

    /// <summary>离开草稿/关闭窗口时立即结算，不再等待静默期。</summary>
    public async Task FlushAsync(Guid draftId)
    {
        lock (_gate)
        {
            if (_scheduled.Remove(draftId, out var cts))
            {
                cts.Cancel();
                cts.Dispose();
            }
        }
        await CommitAsync(draftId).ConfigureAwait(false);
    }

    public async Task FlushAllAsync()
    {
        Guid[] ids;
        lock (_gate)
        {
            foreach (var cts in _scheduled.Values) cts.Cancel();
            ids = [.. _pending.Keys];
            _scheduled.Clear();
        }
        foreach (var draftId in ids)
        {
            await CommitAsync(draftId).ConfigureAwait(false);
        }
    }

    private async Task CommitAsync(Guid draftId)
    {
        string? text;
        lock (_gate)
        {
            _scheduled.Remove(draftId);
            if (!_pending.Remove(draftId, out text)) return;
        }
        await _persist(draftId, text).ConfigureAwait(false);
    }
}

/// <summary>API Key 受保护存储抽象（W-008）。Windows 生产实现走 DPAPI 用户级保护；
/// 不入普通日志、归档或安装包（R-010）。</summary>
public interface ISecretStore
{
    bool Save(string account, string secret);
    string? Read(string account);
    void Delete(string account);
}

/// <summary>测试用内存实现（模拟用户级隔离存储语义）。</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _secrets = new();

    public bool Save(string account, string secret)
    {
        _secrets[account] = secret;
        return true;
    }

    public string? Read(string account) => _secrets.GetValueOrDefault(account);

    public void Delete(string account) => _secrets.Remove(account);
}
