using Tokenizers.HuggingFace.Tokenizer;

namespace DraftZero.Core;

/// <summary>
/// Tokenizers.HuggingFace（Apache-2.0，Rust tokenizers 绑定）适配。
/// 直接从 tokenizer.json 构造，与 Python 原型 / swift-transformers 同源分词。
/// Encode 返回含 &lt;s&gt;/&lt;/s&gt; 特殊符的完整序列（TemplateProcessing），调用方负责 512 截断。
/// </summary>
public sealed class HuggingFaceTokenizerAdapter : ITokenizerAdapter
{
    private readonly global::Tokenizers.HuggingFace.Tokenizer.Tokenizer _tokenizer;

    public HuggingFaceTokenizerAdapter(string tokenizerJsonPath)
    {
        _tokenizer = global::Tokenizers.HuggingFace.Tokenizer.Tokenizer.FromFile(tokenizerJsonPath);
    }

    public long[] Encode(string text)
    {
        var encodings = _tokenizer.Encode(text, addSpecialTokens: true, input2: null,
            includeTypeIds: false, includeTokens: false, includeWords: false,
            includeOffsets: false, includeSpecialTokensMask: false,
            includeOverflowing: false, includeAttentionMask: false, charOffsets: false);
        var first = encodings.First();
        var ids = new long[first.Ids.Count];
        for (int i = 0; i < ids.Length; i++)
        {
            ids[i] = first.Ids[i];
        }
        return ids;
    }

    public void Dispose() { }
}
