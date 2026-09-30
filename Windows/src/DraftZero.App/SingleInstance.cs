using DraftZero.Core;

namespace DraftZero.App;

/// <summary>
/// 单实例保护（W-009 深链可用性前提）：第二个实例不重复打开工作区，
/// 而是把 draftzero:// URL 移交给主实例后退出。
/// 移交通道：工作区目录内 .deeplink 文件（原子覆盖）+ 命名 EventWaitHandle 信号，
/// 全部落在应用自己的数据目录与会话命名空间内。
/// </summary>
public static class SingleInstance
{
    private const string MutexName = @"Local\DraftZero.SingleInstance";
    private const string SignalName = @"Local\DraftZero.DeepLinkSignal";
    private static Mutex? _mutex;
    private static EventWaitHandle? _signal;

    /// <summary>主实例的深链信号（App 启动后读取，供 watcher 等待）。</summary>
    public static EventWaitHandle? SingleInstanceWatch => _signal;

    /// <summary>主实例获取单实例锁；返回 false 表示已有实例在运行。
    /// 命名同步原语仅 Windows 支持；Mac 开发构建退化为未命名对象（不强制单实例、不深链转发）。</summary>
    public static bool TryAcquirePrimary(out EventWaitHandle deepLinkSignal)
    {
        if (OperatingSystem.IsWindows())
        {
            _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
            _signal = new EventWaitHandle(initialState: false, EventResetMode.AutoReset, SignalName);
            deepLinkSignal = _signal;
            return createdNew;
        }
        _mutex = new Mutex(initiallyOwned: true);
        _signal = new EventWaitHandle(initialState: false, EventResetMode.AutoReset);
        deepLinkSignal = _signal;
        return true;
    }

    /// <summary>第二实例：把深链 URL 移交给主实例（写文件 + 信号）。仅 Windows 发布构建可达。</summary>
    public static void ForwardDeepLinkToPrimary(Uri url)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("深链跨实例转发仅在 Windows 发布构建可用");
        }
        var file = DeepLinkFilePath();
        File.WriteAllText(file, url.ToString());
        using var signal = EventWaitHandle.OpenExisting(SignalName);
        signal.Set();
    }

    /// <summary>主实例读取并清除待处理深链（无则返回 null）。</summary>
    public static string? ConsumeDeepLink()
    {
        try
        {
            var file = DeepLinkFilePath();
            if (!File.Exists(file)) return null;
            var url = File.ReadAllText(file);
            File.Delete(file);
            return string.IsNullOrWhiteSpace(url) ? null : url;
        }
        catch
        {
            return null;
        }
    }

    private static string DeepLinkFilePath()
    {
        var (dbPath, _) = AppDatabase.DefaultWorkspace();
        return Path.Combine(Path.GetDirectoryName(dbPath)!, ".deeplink");
    }
}
