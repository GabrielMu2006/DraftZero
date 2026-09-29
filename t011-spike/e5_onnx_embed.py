# -*- coding: utf-8 -*-
"""Embed chunks with intfloat/multilingual-e5-small ONNX weights (downloaded from hf-mirror).

Follows the model card: prefix "query: "/"passage: ", mean pooling over the
attention mask, L2-normalised output. Emits e5.json in the format score.py expects.
"""
import json, os, time
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, "models", "e5-small-onnx")
MAX_LEN = 512
BATCH = 16

def mean_pool(last_hidden, mask):
    mask = mask[:, :, None].astype(np.float32)
    summed = (last_hidden * mask).sum(axis=1)
    counts = np.clip(mask.sum(axis=1), 1e-9, None)
    return summed / counts

def l2n(v):
    return v / np.clip(np.linalg.norm(v, axis=1, keepdims=True), 1e-9, None)

def embed(texts, sess, tok):
    enc = tok.encode_batch(texts)
    ids = np.array([e.ids[:MAX_LEN] for e in enc], dtype=np.int64)
    att = np.array([e.attention_mask[:MAX_LEN] for e in enc], dtype=np.int64)
    tti = np.zeros_like(ids)
    out = []
    for i in range(0, len(texts), BATCH):
        feeds = {"input_ids": ids[i:i+BATCH], "attention_mask": att[i:i+BATCH],
                 "token_type_ids": tti[i:i+BATCH]}
        hidden = sess.run(None, feeds)[0]
        out.append(l2n(mean_pool(hidden, att[i:i+BATCH])))
    return np.vstack(out)

def main():
    tok = Tokenizer.from_file(os.path.join(MODEL_DIR, "tokenizer.json"))
    tok.enable_truncation(MAX_LEN)
    tok.enable_padding()
    so = ort.SessionOptions()
    so.intra_op_num_threads = 8
    sess = ort.InferenceSession(os.path.join(MODEL_DIR, "model.onnx"), so,
                                providers=["CPUExecutionProvider"])
    print("input names:", [i.name for i in sess.get_inputs()],
          "| output:", [o.name for o in sess.get_outputs()], flush=True)

    chunks = json.load(open(os.path.join(HERE, "chunks.json"), encoding="utf-8"))
    texts = [c["text"] for c in chunks]

    t0 = time.time()
    sym = embed(["query: " + t for t in texts], sess, tok)
    t_sym = time.time() - t0
    t0 = time.time()
    pas = embed(["passage: " + t for t in texts], sess, tok)
    t_pas = time.time() - t0
    n = len(texts)
    print(f"embedded {n}x2 in {t_sym + t_pas:.1f}s "
          f"({(n*2)/(t_sym+t_pas):.1f} texts/s, dim={sym.shape[1]})", flush=True)

    out = {"variant_sym": {c["id"]: [round(float(x), 6) for x in v] for c, v in zip(chunks, sym)},
           "variant_asym_q": {c["id"]: [round(float(x), 6) for x in v] for c, v in zip(chunks, sym)},
           "variant_asym_p": {c["id"]: [round(float(x), 6) for x in v] for c, v in zip(chunks, pas)}}
    with open(os.path.join(HERE, "e5.json"), "w", encoding="utf-8") as f:
        json.dump(out, f)
    print("wrote e5.json")

if __name__ == "__main__":
    main()
