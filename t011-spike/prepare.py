# -*- coding: utf-8 -*-
"""Chunk drafts into passage-level pieces and emit chunks.json (shared by both embedders)."""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTSET = os.path.join(HERE, "testset")
MIN_CHUNK = 12  # chars; anything shorter merges into the previous chunk

def split_chunks(text):
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks, buf = [], ""
    for p in paras:
        cand = (buf + "\n" + p).strip() if buf else p
        if len(buf) < MIN_CHUNK:
            buf = cand
        else:
            if len(p) < MIN_CHUNK:
                buf = cand
            else:
                chunks.append(buf); buf = p
    if buf:
        chunks.append(buf)
    # hard-split any paragraph still longer than ~600 chars (simulates long PDF text)
    out = []
    for c in chunks:
        while len(c) > 600:
            cut = c.rfind("。", 0, 600)
            cut = cut if cut > 200 else 600
            out.append(c[:cut + 1].strip()); c = c[cut + 1:].strip()
        if c:
            out.append(c)
    return out

def main():
    docs = {}
    for fn in sorted(os.listdir(TESTSET)):
        if fn.startswith("."):
            continue
        with open(os.path.join(TESTSET, fn), encoding="utf-8") as f:
            docs[fn] = f.read()
    chunks = []
    for doc, text in docs.items():
        for i, c in enumerate(split_chunks(text)):
            chunks.append({"id": f"{doc}::{i}", "doc": doc, "text": c})
    with open(os.path.join(HERE, "chunks.json"), "w", encoding="utf-8") as f:
        json.dump(chunks, f, ensure_ascii=False)
    print(f"{len(docs)} docs -> {len(chunks)} chunks")

if __name__ == "__main__":
    main()
