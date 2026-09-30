using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DraftZero.Core;

namespace DraftZero.App.Platform;

/// <summary>
/// Windows 用户级受保护 Key 存储（W-008）：DPAPI CurrentUser 作用域，
/// 密文仅当前 Windows 用户可解；文件落在 %LocalAppData%\DraftZero 下，
/// 不入普通日志、迁移归档或安装包（R-010）。
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private static string StorePath()
    {
        var (dbPath, _) = AppDatabase.DefaultWorkspace();
        return Path.Combine(Path.GetDirectoryName(dbPath)!, "secrets.bin");
    }

    public bool Save(string account, string secret)
    {
        try
        {
            var dict = LoadAll();
            dict[account] = secret;
            var json = JsonSerializer.SerializeToUtf8Bytes(dict);
            var encrypted = ProtectedData.Protect(json, Encoding.UTF8.GetBytes("DraftZero/Keyring"), DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(StorePath())!);
            File.WriteAllBytes(StorePath(), encrypted);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public string? Read(string account)
    {
        try
        {
            var dict = LoadAll();
            return dict.GetValueOrDefault(account);
        }
        catch
        {
            return null;
        }
    }

    public void Delete(string account)
    {
        try
        {
            var dict = LoadAll();
            if (dict.Remove(account))
            {
                var json = JsonSerializer.SerializeToUtf8Bytes(dict);
                var encrypted = ProtectedData.Protect(json, Encoding.UTF8.GetBytes("DraftZero/Keyring"), DataProtectionScope.CurrentUser);
                File.WriteAllBytes(StorePath(), encrypted);
            }
        }
        catch
        {
            // 删除失败不影响本地工作流。
        }
    }

    private Dictionary<string, string> LoadAll()
    {
        var path = StorePath();
        if (!File.Exists(path)) return [];
        var json = ProtectedData.Unprotect(File.ReadAllBytes(path), Encoding.UTF8.GetBytes("DraftZero/Keyring"), DataProtectionScope.CurrentUser);
        return JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? [];
    }
}
