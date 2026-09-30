using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using DraftZero.App.Platform;
using DraftZero.App.Services;

namespace DraftZero.App;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // 平台服务：Windows 用 DPAPI + Windows.Data.Pdf；Mac 开发用内存实现
#if WINDOWS
            var secretStore = new DpapiSecretStore();
            var pdfRenderer = new WindowsPdfPageRenderer();
#else
            var secretStore = new DevSecretStore();
            var pdfRenderer = new StubPdfPageRenderer();
#endif
            var model = new AppViewModel(secretStore);
            desktop.MainWindow = new MainWindow(model, pdfRenderer);
            // 深链 argv：DraftZero-Setup 注册 draftzero:// 后以 argv 传入
            var linkArg = desktop.Args?.FirstOrDefault(a =>
                a.StartsWith("draftzero://", StringComparison.OrdinalIgnoreCase));
            _ = model.BootstrapAsync().ContinueWith(_ =>
            {
                Avalonia.Threading.Dispatcher.UIThread.Post(async () =>
                {
                    await model.BootstrapSemanticAsync();
                    if (linkArg is not null)
                    {
                        await model.RouteDeepLinkAsync(new Uri(linkArg));
                    }
                });
            });

            // 第二实例移交的深链（单实例信号 → 主实例路由）
            if (SingleInstance.SingleInstanceWatch is { } watch)
            {
                _ = Task.Run(async () =>
                {
                    while (watch.WaitOne())
                    {
                        var url = SingleInstance.ConsumeDeepLink();
                        if (url is null) continue;
                        Avalonia.Threading.Dispatcher.UIThread.Post(async () =>
                        {
                            try { await model.RouteDeepLinkAsync(new Uri(url)); }
                            catch { /* 非法 URL 丢弃，不影响主实例 */ }
                        });
                    }
                });
            }
        }
        base.OnFrameworkInitializationCompleted();
    }
}
