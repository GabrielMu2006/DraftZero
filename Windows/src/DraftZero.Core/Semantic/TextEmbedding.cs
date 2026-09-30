using System.Security.Cryptography;

namespace DraftZero.Core;

/// <summary>
/// 文本向量器抽象。生产实现是随应用分发的 multilingual-e5-small（ONNX，E5OnnxEmbedder）；
/// 测试注入确定性假向量器，离线可跑（对齐 Mac TextEmbedding.swift）。
/// </summary>
public interface ITextEmbedding
{
    int Dimension { get; }

    /// <summary>返回与输入等长的 L2 归一化向量。</summary>
    float[][] Embed(string[] texts);
}

public static class TextEmbeddingExtensions
{
    public static float[] Embed(this ITextEmbedding e, string text) => e.Embed([text])[0];
}

/// <summary>确定性测试向量器：把文本 hash 映射到归一化向量；只用于无模型离线测试。</summary>
public sealed class FakeEmbedder : ITextEmbedding
{
    public int Dimension { get; }

    public FakeEmbedder(int dimension = 64) => Dimension = dimension;

    public float[][] Embed(string[] texts)
    {
        var result = new float[texts.Length][];
        for (int t = 0; t < texts.Length; t++)
        {
            var v = new float[Dimension];
            // 以 4 字节窗口从 SHA-256 流派生确定性数值。
            var stream = new List<byte>();
            int round = 0;
            while (stream.Count < Dimension * 4)
            {
                stream.AddRange(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes($"{t}\u0001{round}")));
                round++;
            }
            for (int i = 0; i < Dimension; i++)
            {
                uint raw = (uint)(stream[i * 4] | (stream[i * 4 + 1] << 8) | (stream[i * 4 + 2] << 16) | (stream[i * 4 + 3] << 24));
                float x = raw / (float)uint.MaxValue * 2f - 1f;
                v[i] = x;
            }
            result[t] = Normalize(v);
        }
        return result;
    }

    internal static float[] Normalize(float[] v)
    {
        double sum = 0;
        foreach (var x in v) sum += (double)x * x;
        var norm = Math.Sqrt(sum);
        if (norm < 1e-12) return v;
        for (int i = 0; i < v.Length; i++) v[i] = (float)(v[i] / norm);
        return v;
    }
}

public class SemanticModelMissingException : Exception
{
    public SemanticModelMissingException()
        : base("本机语义模型缺失（应用包损坏），可重建索引但语义线索暂不可用") { }
}

public class SemanticInferenceException : Exception
{
    public SemanticInferenceException(string detail)
        : base($"本机语义推理失败：{detail}") { }
}
