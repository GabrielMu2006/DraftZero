using System.Reflection;

namespace DraftZero.App.Services;

/// <summary>
/// 离线模型定位（W-004：随应用分发，断网可用）。
/// 安装布局：model/ 目录在应用根目录（Inno Setup 打包）；开发布局：仓库 Windows/models/。
/// </summary>
public static class ModelLocator
{
    public sealed record LocatedModel(string ModelOnnxPath, string TokenizerJsonPath);

    public static LocatedModel Locate()
    {
        var exeDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(exeDir, "model"),
            Path.Combine(exeDir, "..", "..", "..", "..", "..", "models"),
            Path.Combine(exeDir, "..", "..", "..", "..", "models"),
        };
        foreach (var dir in candidates.Select(Path.GetFullPath))
        {
            var model = Path.Combine(dir, "model.onnx");
            var tokenizer = Path.Combine(dir, "tokenizer.json");
            if (File.Exists(model) && File.Exists(tokenizer))
            {
                return new LocatedModel(model, tokenizer);
            }
        }
        throw new FileNotFoundException(
            $"本机语义模型缺失（应用包损坏），可重建索引但语义线索暂不可用。已查找：{string.Join("；", candidates)}");
    }
}
