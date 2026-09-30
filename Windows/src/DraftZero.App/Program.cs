using Avalonia;
using System;

namespace DraftZero.App;

internal static class Program
{
    /// <summary>启动参数里的 draftzero:// 链接（由 App 在数据就绪后路由）。</summary>
    public static string? LaunchDeepLink { get; private set; }

    [STAThread]
    public static void Main(string[] args)
    {
        LaunchDeepLink = Array.Find(args, a =>
            a.StartsWith("draftzero://", StringComparison.OrdinalIgnoreCase));

        // 单实例（W-009）：第二个实例不重复打开工作区；带深链时移交给主实例后退出。
        if (!SingleInstance.TryAcquirePrimary(out _))
        {
            if (LaunchDeepLink is not null)
            {
                try { SingleInstance.ForwardDeepLinkToPrimary(new Uri(LaunchDeepLink)); }
                catch { /* 主实例信号不可达时静默退出（不弹错误窗） */ }
            }
            return;
        }

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>()
        .UsePlatformDetect()
        .LogToTrace();
}
