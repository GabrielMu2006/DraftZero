# -*- coding: utf-8 -*-
"""Embed chunks with multilingual-e5-small via fastembed; two prefix variants."""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))

def embed_all(texts, model):
    return list(model.embed(texts))

def main():
    from fastembed import TextEmbedding
    chunks = json.load(open(os.path.join(HERE, "chunks.json"), encoding="utf-8"))
    texts = [c["text"] for c in chunks]
    t0 = time.time()
    model = TextEmbedding(model_name="intfloat/multilingual-e5-small")
    print(f"model ready in {time.time()-t0:.1f}s", flush=True)

    t0 = time.time()
    sym_q = embed_all(["query: " + t for t in texts], model)      # symmetric variant
    sym_p = embed_all(["passage: " + t for t in texts], model)    # for asymmetric variant
    print(f"embedded {len(texts)} x2 in {time.time()-t0:.1f}s", flush=True)

    out = {"variant_sym": {c["id"]: [round(x, 6) for x in v] for c, v in zip(chunks, sym_q)},
           "variant_asym_q": {c["id"]: [round(x, 6) for x in v] for c, v in zip(chunks, sym_q)},
           "variant_asym_p": {c["id"]: [round(x, 6) for x in v] for c, v in zip(chunks, sym_p)}}
    with open(os.path.join(HERE, "e5.json"), "w", encoding="utf-8") as f:
        json.dump(out, f)
    print("wrote e5.json")

if __name__ == "__main__":
    main()
