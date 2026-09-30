using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using System.Numerics.Tensors;

namespace DraftZero.Core;

/// <summary>
/// multilingual-e5-small ONNX CPU 推理（计划 §2）：同一 tokenizer.json、
/// "query: " 前缀、512 token 截断、attention-mask mean pooling、L2 归一化、384 维向量。
/// 与 Python 原型（t011-spike/e5_onnx_embed.py）与 Mac CoreML 黄金样本同一口径；
/// model.onnx 不含 pooling/L2，由本类完成（Mac CoreML 模型内置，结果对齐）。
/// </summary>
public sealed class E5OnnxEmbedder : ITextEmbedding, IDisposable
{
    public const string QueryPrefix = "query: ";
    public const int MaxTokens = 512;
    public const int ExpectedDimension = 384;

    private readonly ITokenizerAdapter _tokenizer;
    private readonly InferenceSession _session;
    private readonly string _inputIdsName;
    private readonly string _attentionMaskName;
    private readonly string? _tokenTypeIdsName;
    private readonly string _outputName;
    private readonly object _runLock = new();

    public int Dimension => ExpectedDimension;

    public E5OnnxEmbedder(string modelOnnxPath, string tokenizerJsonPath)
        : this(modelOnnxPath, new HuggingFaceTokenizerAdapter(tokenizerJsonPath))
    {
    }

    public E5OnnxEmbedder(string modelOnnxPath, ITokenizerAdapter tokenizer)
    {
        _tokenizer = tokenizer;
        var options = new SessionOptions
        {
            ExecutionMode = ExecutionMode.ORT_SEQUENTIAL,
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
        };
        options.IntraOpNumThreads = Math.Max(2, Environment.ProcessorCount / 2);
        _session = new InferenceSession(modelOnnxPath, options);

        foreach (var name in _session.InputMetadata.Keys)
        {
            if (name.Contains("input_ids")) _inputIdsName = name;
            else if (name.Contains("attention_mask")) _attentionMaskName = name;
            else if (name.Contains("token_type")) _tokenTypeIdsName = name;
        }
        _inputIdsName ??= _session.InputMetadata.Keys.First();
        _attentionMaskName ??= "attention_mask";
        _outputName = _session.OutputMetadata.Keys
            .OrderBy(n => !n.Contains("hidden", StringComparison.OrdinalIgnoreCase))
            .ThenBy(n => n, StringComparer.Ordinal)
            .First();
    }

    public float[][] Embed(string[] texts)
    {
        if (texts.Length == 0) return [];
        var result = new float[texts.Length][];
        lock (_runLock)
        {
            for (int i = 0; i < texts.Length; i++)
            {
                result[i] = EmbedSingle(texts[i]);
            }
        }
        return result;
    }

    private float[] EmbedSingle(string text)
    {
        var ids = _tokenizer.Encode(QueryPrefix + text);
        if (ids.Length > MaxTokens)
        {
            ids = ids[..MaxTokens];
        }
        var seqLen = Math.Max(ids.Length, 1);
        var inputIds = new long[seqLen];
        var attentionMask = new long[seqLen];
        for (int i = 0; i < seqLen; i++)
        {
            inputIds[i] = i < ids.Length ? ids[i] : 0;
            attentionMask[i] = 1;
        }
        var shape = new[] { 1, seqLen };
        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor(_inputIdsName, new DenseTensor<long>(inputIds, shape)),
            NamedOnnxValue.CreateFromTensor(_attentionMaskName, new DenseTensor<long>(attentionMask, shape)),
        };
        if (_tokenTypeIdsName is not null)
        {
            inputs.Add(NamedOnnxValue.CreateFromTensor(_tokenTypeIdsName, new DenseTensor<long>(new long[seqLen], shape)));
        }

        float[] pooled;
        using (var outputs = _session.Run(inputs))
        {
            var output = outputs.First(o => o.Name == _outputName);
            var tensor = output.AsTensor<float>();
            var dims = tensor.Dimensions; // [1, seq, hidden] 或 [1, seq, 1, hidden]
            int hidden = dims[^1];
            int tokens = dims[^2];
            if (hidden != ExpectedDimension)
            {
                throw new SemanticInferenceException($"输出维度异常：{hidden} ≠ {ExpectedDimension}");
            }
            // attention-mask mean pooling（Python np.clip 求和/计数口径）+ L2 归一化。
            pooled = new float[hidden];
            var scratch = new float[hidden];
            float maskSum = 0;
            for (int t = 0; t < tokens; t++)
            {
                for (int h = 0; h < hidden; h++)
                {
                    scratch[h] = tensor[0, t, h];
                }
                TensorPrimitives.Add(pooled, scratch, pooled);
                maskSum += 1;
            }
            if (maskSum < 1e-9f) maskSum = 1e-9f;
            TensorPrimitives.Divide(pooled, maskSum, pooled);
        }
        var norm = MathF.Sqrt(TensorPrimitives.Dot(pooled, pooled));
        if (norm < 1e-9f) norm = 1e-9f;
        TensorPrimitives.Divide(pooled, norm, pooled);
        return pooled;
    }

    /// <summary>测试辅助：暴露分词（含特殊符，未截断）。M0 黄金样本对齐用。</summary>
    public long[] TokenizeForTest(string text) => _tokenizer.Encode(text);

    public void Dispose()
    {
        _session.Dispose();
        _tokenizer.Dispose();
    }
}

/// <summary>分词器适配：屏蔽具体实现（HF 绑定 / 测试假分词器）。</summary>
public interface ITokenizerAdapter : IDisposable
{
    /// <summary>返回含特殊符（&lt;s&gt;…&lt;/s&gt;）的完整 token id 序列。</summary>
    long[] Encode(string text);
}
