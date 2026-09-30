using DraftZero.Core;

namespace DraftZero.App.Platform;

/// <summary>
/// Mac 开发构建的 Key 存储占位：进程内存保存（不落盘）。
/// Windows 发布构建使用 DpapiSecretStore（用户级 DPAPI）。
/// 仅用于 Mac 上跑通 UI 流程；真实 Key 应在 Windows 上填写。
/// </summary>
public sealed class DevSecretStore : ISecretStore
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
