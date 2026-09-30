using System;
using System.Linq;
using System.Collections.Generic;
using Tokenizers.HuggingFace.Tokenizer;

var tok = global::Tokenizers.HuggingFace.Tokenizer.Tokenizer.FromFile(
    "/Users/gabrielmu/Documents/DraftZero-experiments-2026-09-29/t011-spike/models/e5-small-onnx/tokenizer.json");
Console.WriteLine("loaded ok");
var text = "query: 你好世界 hello benchmark";
var result = tok.Encode(text, true, null, false, false, false, false, false, false, false, false);
Console.WriteLine($"result type: {result.GetType().FullName}");
foreach (var item in (System.Collections.IEnumerable)result)
{
    Console.WriteLine($"  item type: {item.GetType().FullName} value={item}");
}
var ids = result.First();
if (ids is global::Tokenizers.HuggingFace.Tokenizer.Encoding enc)
{
    Console.WriteLine("ids: " + string.Join(",", enc.Ids.Take(20)));
    Console.WriteLine("mask: " + string.Join(",", enc.AttentionMask.Take(20)));
    Console.WriteLine("count: " + enc.Ids.Count);
}
else
{
    // maybe tuple
    var props = ids.GetType().GetProperties();
    foreach (var p in props) Console.WriteLine($"  prop {p.Name}: {p.PropertyType.Name} = {p.GetValue(ids)}");
}
