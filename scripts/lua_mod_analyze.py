#!/usr/bin/env python3
# lua_mod_analyze_cluster_centric_sentences.py
#
# Clean, cluster-centric analyzer with sentence-style analysis.
# Builds on the previous clean version and adds deterministic summaries.

import sys
import re
from pathlib import Path
from collections import defaultdict, Counter, deque

GROUP_BASE = 0.65
SPLIT_BASE = 0.35
BIAS_RANGE = (-1.0, 1.0)
CLUSTER_THRESHOLD = 0.35

FUNC_DEF_RE = re.compile(r"\bfunction\s+([a-zA-Z0-9_.:]+)")
CALL_RE = re.compile(r"\b([a-zA-Z0-9_.:]+)\s*\(")
IDENT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")
CONTEXT_ROOT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)[\.:][a-zA-Z_][a-zA-Z0-9_]*")

STOPWORDS = {
    "local","function","end","if","then","else","for","do","while",
    "return","nil","true","false","and","or","not"
}

def extract_identifiers(text):
    return {i for i in IDENT_RE.findall(text) if i not in STOPWORDS}

def extract_context_roots(text):
    return {m.group(1) for m in CONTEXT_ROOT_RE.finditer(text)}

def compute_loc(text):
    loc = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        loc += 1
    return loc

def parse_lua(path):
    funcs = {}
    calls = defaultdict(set)
    idents = {}
    roots = {}
    locs = {}
    try:
        text = path.read_text()
    except Exception:
        return {}, calls, {}, {}, {}

    for m in FUNC_DEF_RE.finditer(text):
        funcs[m.group(1)] = m.end()

    names = list(funcs.keys())
    for i, name in enumerate(names):
        start = funcs[name]
        end = funcs[names[i+1]] if i+1 < len(names) else len(text)
        body = text[start:end]
        idents[name] = extract_identifiers(body)
        roots[name] = extract_context_roots(body)
        locs[name] = compute_loc(body)
        for m in CALL_RE.finditer(body):
            calls[name].add(m.group(1))

    return set(funcs.keys()), calls, idents, roots, locs

def analyze(paths):
    functions = {}
    calls = defaultdict(set)
    idents = {}
    context_roots = {}
    func_loc = {}
    func_to_file = {}

    for p in paths:
        files = list(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            fns, c, ids, roots, locs = parse_lua(f)
            for fn in fns:
                functions[fn] = f
                func_to_file[fn] = f.name
                func_loc[fn] = locs.get(fn, 0)
            for k, v in c.items():
                calls[k].update(v)
            idents.update(ids)
            context_roots.update(roots)

    fanout = {fn: len(calls.get(fn, [])) for fn in functions}

    def coupling(a, b):
        score = 0.0
        shared_roots = context_roots.get(a, set()) & context_roots.get(b, set())
        if shared_roots:
            score += min(0.8, 0.4 + 0.2 * len(shared_roots))
        shared = idents.get(a, set()) & idents.get(b, set())
        if len(shared) >= 3:
            score += min(0.3, len(shared) * 0.03)
        if b in calls[a]:
            score += 0.5 / max(1, fanout[a])
        score -= min(0.5, fanout[b] * 0.03)
        if b in calls[a] and a not in calls[b]:
            score -= 0.05
        return max(0.0, min(1.0, score))

    adj = defaultdict(set)
    for a in functions:
        for b in calls[a]:
            if b not in functions or a == b:
                continue
            c = coupling(a, b)
            if c >= CLUSTER_THRESHOLD:
                adj[a].add(b)
                adj[b].add(a)

    visited = set()
    clusters = []
    for fn in functions:
        if fn in visited:
            continue
        q = deque([fn])
        comp = set()
        while q:
            cur = q.popleft()
            if cur in visited:
                continue
            visited.add(cur)
            comp.add(cur)
            q.extend(adj[cur])
        if len(comp) > 1:
            clusters.append(comp)

    all_edges = []
    seen = set()
    for a in functions:
        for b in calls[a]:
            if b not in functions or a == b:
                continue
            pair = tuple(sorted((a,b)))
            if pair in seen:
                continue
            seen.add(pair)
            c = coupling(a,b)
            if c >= 0.15:
                all_edges.append((a,b,c))

    print(f"CLUSTERS (coupling ≥ {CLUSTER_THRESHOLD:.2f})\n")

    for i, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        internal = [(a,b,c) for (a,b,c) in all_edges if a in cluster and b in cluster]
        internal.sort(key=lambda x: -x[2])

        # Sentence-style analysis
        degree = Counter()
        for a,b,_ in internal:
            degree[a] += 1
            degree[b] += 1
        central = degree.most_common(1)[0][0] if degree else sorted(cluster)[0]

        root_counts = Counter()
        for fn in cluster:
            for r in context_roots.get(fn, []):
                root_counts[r] += 1
        dom_root = root_counts.most_common(1)[0][0] if root_counts else None

        total = sum(func_loc.get(f,0) for f in cluster)
        by_file = Counter()
        for f in cluster:
            by_file[func_to_file.get(f,'<unknown>')] += func_loc.get(f,0)
        dom_file, dom_loc = by_file.most_common(1)[0]
        dom_pct = int(round(100 * dom_loc / total)) if total else 0

        print(f"CLUSTER {i}")
        print(f"Functions ({len(cluster)}):")
        for fn in sorted(cluster):
            print(f"  {fn}")

        print("Analysis:")
        if dom_root:
            print(
                f"This cluster is organized around {central}, with cohesion driven primarily by shared '{dom_root}' context usage."
            )
        else:
            print(
                f"This cluster is organized around {central}, with cohesion driven by internal call structure rather than shared context."
            )

        if dom_pct >= 67:
            print(
                f"Most logic resides in {dom_file} ({dom_pct}% of cluster LOC), indicating an existing structural center."
            )
        else:
            files = ', '.join(by_file.keys())
            print(
                f"Logic is split across {files}, with no single file fully dominating the cluster."
            )

        if len(by_file) == 1:
            print(f"All functions are co-located in {dom_file}.")

        print("Files:")
        for f, loc in by_file.items():
            pct = int(round(100 * loc / total)) if total else 0
            print(f"  {f}: {pct}%")

        if internal:
            print("Strong internal edges:")
            for a,b,c in internal[:5]:
                print(f"  {a} ↔ {b}  ({c:.2f})")

        print()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: lua_mod_analyze_cluster_centric_sentences.py <path> [...]")
        sys.exit(1)
    analyze([Path(p) for p in sys.argv[1:]])
