# -*- coding: utf-8 -*-
"""T-011 spike scoring: candidate lists per scorer -> SPEC quality-gate metrics.

Scorers: e5-sym / e5-asym (multilingual-e5-small), nl (Apple NLEmbedding),
literal (char-bigram/word Jaccard + title overlap), e5+literal, nl+literal.
Metrics: recall@5 (top-5 candidates contain >=1 same-thread doc) and
prec@3 (fraction of top-3 leads that are truly same-thread/duplicate).
"""
import json, os, re, itertools

HERE = os.path.dirname(os.path.abspath(__file__))

def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return json.load(f)

gt = load("groundtruth.json")
chunks = load("chunks.json")
e5 = load("e5.json")
nl = load("nl.json")

doc_of = {c["id"]: c["doc"] for c in chunks}
docs = sorted({c["doc"] for c in chunks})

thread = {}
for g, members in gt["threads"].items():
    for m in members:
        thread[m] = g
partners = {d: set() for d in docs}
for d, g in thread.items():
    partners[d] |= {m for m in gt["threads"][g] if m != d}
for a, b in gt["duplicates"]:
    partners[a].add(b); partners[b].add(a)

def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(x * x for x in b) ** 0.5
    return dot / (na * nb + 1e-12)

def doc_matrix(vec_map):
    """doc-doc score = max over chunk pairs, keeping the best evidence pair."""
    by_doc = {}
    for c in chunks:
        if c["id"] in vec_map:
            by_doc.setdefault(c["doc"], []).append((c["id"], vec_map[c["id"]]))
    M = {}
    for d1, d2 in itertools.combinations(docs, 2):
        best, best_pair = -1.0, None
        for i1, v1 in by_doc[d1]:
            for i2, v2 in by_doc[d2]:
                s = cos(v1, v2)
                if s > best:
                    best, best_pair = s, (i1, i2)
        M[(d1, d2)] = (best, best_pair)
    return M

def asym_matrix():
    """query(doc1) -> passage(doc2), take max over both directions."""
    q_by, p_by = {}, {}
    for c in chunks:
        q = e5["variant_asym_q"].get(c["id"]); p = e5["variant_asym_p"].get(c["id"])
        if q: q_by.setdefault(c["doc"], []).append(q)
        if p: p_by.setdefault(c["doc"], []).append(p)
    M = {}
    for d1, d2 in itertools.combinations(docs, 2):
        best = -1.0
        for vq in q_by[d1]:
            for vp in p_by[d2]:
                best = max(best, cos(vq, vp))
        for vq in q_by[d2]:
            for vp in p_by[d1]:
                best = max(best, cos(vq, vp))
        M[(d1, d2)] = (best, None)
    return M

def nl_doc_matrix():
    by_doc = {}
    for c in chunks:
        by_doc.setdefault(c["doc"], []).append(c["id"])
    det = nl["detected"]
    M = {}
    for d1, d2 in itertools.combinations(docs, 2):
        best, best_pair = -1.0, None
        for i1 in by_doc[d1]:
            for i2 in by_doc[d2]:
                same_zh = det.get(i1, "").startswith("zh") and det.get(i2, "").startswith("zh")
                key = "zh" if same_zh else "en"
                v1 = nl["vectors"][i1].get(key); v2 = nl["vectors"][i2].get(key)
                if v1 is None or v2 is None:
                    continue
                s = cos(v1, v2)
                if s > best:
                    best, best_pair = s, (i1, i2)
        M[(d1, d2)] = (best, best_pair)
    return M

def doc_tokens(doc):
    toks = set()
    for c in chunks:
        if c["doc"] != doc:
            continue
        t = c["text"].lower()
        toks |= set(re.findall(r"[a-z0-9]+", t))
        toks |= {t[i:i+2] for i in range(len(t)-1)
                 if "\u4e00" <= t[i] <= "\u9fff" and "\u4e00" <= t[i+1] <= "\u9fff"}
    return toks

def literal_matrix():
    title_tokens = {d: set(re.findall(r"[a-zA-Z0-9]+|[\u4e00-\u9fff]", d.lower())) for d in docs}
    toks = {d: doc_tokens(d) for d in docs}
    M = {}
    for d1, d2 in itertools.combinations(docs, 2):
        body = len(toks[d1] & toks[d2]) / (len(toks[d1] | toks[d2]) + 1e-9)
        tt = len(title_tokens[d1] & title_tokens[d2]) / (len(title_tokens[d1] | title_tokens[d2]) + 1e-9)
        M[(d1, d2)] = (0.7 * body + 0.3 * tt, None)
    return M

def combine(M1, M2, w1=0.7):
    return {k: (w1 * M1[k][0] + (1 - w1) * M2[k][0], M1[k][1]) for k in M1}

def candidates(M, d):
    out = []
    for (a, b), (s, pair) in M.items():
        if s is None or s < 0:
            continue
        if a == d: out.append((s, b, pair))
        elif b == d: out.append((s, a, pair))
    return sorted(out, reverse=True)

def evaluate(name, M):
    hits, eligible, prec_num, prec_den, misses = 0, 0, 0, 0, []
    for d in docs:
        if d not in thread:
            continue
        eligible += 1
        top5 = [c[1] for c in candidates(M, d)[:5]]
        if any(t in partners[d] for t in top5):
            hits += 1
        else:
            misses.append(d)
        for t in [c[1] for c in candidates(M, d)[:3]]:
            prec_den += 1
            if t in partners[d]:
                prec_num += 1
    print(f"{name:12s} recall@5={hits/eligible*100:5.1f}% ({hits}/{eligible})   "
          f"prec@3={prec_num/prec_den*100:5.1f}% ({prec_num}/{prec_den})   misses={misses or '-'}")
    return hits / eligible, prec_num / prec_den

print("threads:", {g: len(m) for g, m in gt["threads"].items()}, "| unrelated:", len(gt["unrelated"]))
print()

e5_sym_M = doc_matrix(e5["variant_sym"])
e5_asym_M = asym_matrix()
nl_M = nl_doc_matrix()
lit_M = literal_matrix()

evaluate("e5-sym", e5_sym_M)
evaluate("e5-asym", e5_asym_M)
evaluate("nl", nl_M)
evaluate("literal", lit_M)
evaluate("e5+literal", combine(e5_sym_M, lit_M))
evaluate("nl+literal", combine(nl_M, lit_M))

print()
for a, b in gt["duplicates"]:
    rank = [i for i, (s, t, _) in enumerate(candidates(e5_sym_M, a), 1) if t == b]
    top = candidates(e5_sym_M, a)[0] if candidates(e5_sym_M, a) else None
    print(f"duplicate (e5-sym): '{b}' rank for '{a}' = {rank[0] if rank else '>all'} (top score {top[0]:.3f})")

def is_en(d):
    return re.search(r"[a-zA-Z]", d) is not None and not re.search(r"[\u4e00-\u9fff]", d)

same, diff = [], []
for (d1, d2), (s, _) in e5_sym_M.items():
    if thread.get(d1) and thread.get(d1) == thread.get(d2) and is_en(d1) != is_en(d2):
        same.append(s)
    elif thread.get(d1) is None and thread.get(d2) is None and is_en(d1) != is_en(d2):
        diff.append(s)
if same and diff:
    print(f"cross-language e5-sym: same-thread mean={sum(same)/len(same):.3f} (n={len(same)}) "
          f"vs unrelated mean={sum(diff)/len(diff):.3f} (n={len(diff)})")

# NL embedding: cross-language capability check on thread A
nl_same, nl_diff = [], []
for (d1, d2), (s, _) in nl_M.items():
    if thread.get(d1) and thread.get(d1) == thread.get(d2) and is_en(d1) != is_en(d2):
        nl_same.append(s)
    elif thread.get(d1) is None and thread.get(d2) is None and is_en(d1) != is_en(d2):
        nl_diff.append(s)
if nl_same or nl_diff:
    print(f"cross-language nl   : same-thread mean={sum(nl_same)/max(len(nl_same),1):.3f} (n={len(nl_same)}) "
          f"vs unrelated mean={sum(nl_diff)/max(len(nl_diff),1):.3f} (n={len(nl_diff)})")
