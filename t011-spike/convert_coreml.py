# -*- coding: utf-8 -*-
"""multilingual-e5-small -> CoreML（内嵌 mean pooling + L2 归一化，fp16 + int8 权重量化）。
与 T-011 已验证的 ONNX 路径做逐句一致性校验；量化后体积对标 ONNX int8（~118MB）。"""
import os, sys
import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
)
from transformers import AutoModel

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, "models", "e5-small-onnx")

class E5Pooling(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
    def forward(self, input_ids, attention_mask):
        hidden = self.model(input_ids=input_ids.long(),
                            attention_mask=attention_mask.long()).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)          # [1, seq, 1]
        summed = (hidden * mask).sum(1)                               # [1, hid]
        counts = mask.sum(1).clamp(min=1e-9)
        mean = summed / counts
        norm = mean.norm(dim=-1, keepdim=True).clamp(min=1e-12)
        return mean / norm                                            # [1, 384]

def convert(precision):
    model = AutoModel.from_pretrained(MODEL_DIR)
    model.eval()
    wrapped = E5Pooling(model).eval()
    example = (torch.ones(1, 64, dtype=torch.int32), torch.ones(1, 64, dtype=torch.int32))
    traced = torch.jit.trace(wrapped, example, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, 512)), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, ct.RangeDim(1, 512)), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=precision,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        minimum_deployment_target=ct.target.macOS14,
    )
    return mlmodel

def embed_with(mlmodel, tok, texts):
    rows = []
    for t in texts:
        e = tok.encode("query: " + t)
        ids = np.array([e.ids[:512]], dtype=np.int32)
        att = np.array([e.attention_mask[:512]], dtype=np.int32)
        pred = mlmodel.predict({"input_ids": ids, "attention_mask": att})
        rows.append(np.array(pred["embedding"])[0])
    return np.array(rows)

def main():
    import onnxruntime as ort
    from tokenizers import Tokenizer

    print("converting fp16…", flush=True)
    fp16 = convert(ct.precision.FLOAT16)
    fp16.save(os.path.join(MODEL_DIR, "e5_small_fp16.mlpackage"))

    print("quantizing weights to int8…", flush=True)
    opt_config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=64))
    int8 = linear_quantize_weights(fp16, opt_config)
    int8.save(os.path.join(MODEL_DIR, "e5_small_int8.mlpackage"))
    print("quantized saved", flush=True)

    tok = Tokenizer.from_file(os.path.join(MODEL_DIR, "tokenizer.json"))
    tok.enable_truncation(512)
    sess = ort.InferenceSession(os.path.join(MODEL_DIR, "model.onnx"), providers=["CPUExecutionProvider"])

    def onnx_embed(texts):
        encs = [tok.encode("query: " + t) for t in texts]
        maxlen = min(512, max(len(e.ids) for e in encs))
        ids = np.zeros((len(encs), maxlen), dtype=np.int64)
        att = np.zeros((len(encs), maxlen), dtype=np.int64)
        for i, e in enumerate(encs):
            n = min(len(e.ids), maxlen)
            ids[i, :n] = e.ids[:n]
            att[i, :n] = e.attention_mask[:n]
        out = sess.run(None, {"input_ids": ids, "attention_mask": att,
                              "token_type_ids": np.zeros_like(ids)})[0]
        mask = att[:, :, None].astype(np.float32)
        emb = (out * mask).sum(1) / np.clip(mask.sum(1), 1e-9, None)
        return emb / np.clip(np.linalg.norm(emb, axis=1, keepdims=True), 1e-9, None)

    texts = []
    testset = os.path.join(HERE, "testset")
    for name in sorted(os.listdir(testset))[:10]:
        with open(os.path.join(testset, name), encoding="utf-8") as f:
            texts.append(f.read()[:300])
    reference = onnx_embed(texts)

    for name, model_obj in [("fp16", fp16), ("int8", int8)]:
        got = embed_with(model_obj, tok, texts)
        cos = (reference * got).sum(1)
        print(f"parity[{name}]: min={cos.min():.5f} mean={cos.mean():.5f}", flush=True)

    print("DONE")

if __name__ == "__main__":
    main()
