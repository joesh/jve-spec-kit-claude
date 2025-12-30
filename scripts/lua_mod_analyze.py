#!/usr/bin/env python3
# lua_mod_analyze_cluster_centric_clean.py
#
# Clean rebuild based on original lua_mod_analyze.py, with:
# - context-root extraction
# - relaxed directional penalty
# - cluster-centric output
#
# No incremental patching. This file stands alone.

import sys
import re
import math
import argparse
from pathlib import Path
from collections import defaultdict, deque

GROUP_BASE = 0.65
SPLIT_BASE = 0.35
BIAS_RANGE = (-1.0, 1.0)
CLUSTER_THRESHOLD = 0.35

HEADER_RE = re.compile(r"--\s*@(?P<key>\w+)\s+(?P<val>.+)")
FUNC_DEF_RE = re.compile(r"\bfunction\s+([a-zA-Z0-9_.:]+)")
CALL_RE = re.compile(r"\b([a-zA-Z0-9_.:]+)\s*\(")
IDENT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")
CONTEXT_ROOT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)[\.:][a-zA-Z_][a-zA-Z0-9_]*")

STOPWORDS = {
    "local","function","end","if","then","else","for","do","while",
    "return","nil","true","false","and","or","not"
}

def parse_headers(path):
    module = None
    scope = "file"
    confidence = "implicit"
    try:
        with path.open() as f:
            for _ in range(12):
                line = f.readline()
                if not line.startswith("--"):
                    break
                m = HEADER_RE.match(line)
                if not m:
                    continue
                k = m.group("key")
                v = m.group("val").strip()
                if k == "module":
                    module = v
                elif k == "scope":
                    scope = v
                elif k == "confidence":
                    confidence = v
    except Exception:
        pass
    return {"module": module, "scope": scope, "confidence": confidence}

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
        return {}, calls, {}, {}, {}, {}

    for m in FUNC_DEF_RE.finditer(text):
        funcs[m.group(1)] = m.end()

    names = list(funcs.keys())
    ranges = []
    for i, name in enumerate(names):
        start = funcs[name]
        end = funcs[names[i+1]] if i+1 < len(names) else len(text)
        ranges.append((name, start, end))

    for name, start, end in ranges:
        body = text[start:end]
        idents[name] = extract_identifiers(body)
        roots[name] = extract_context_roots(body)
        locs[name] = compute_loc(body)
        for m in CALL_RE.finditer(body):
            calls[name].add(m.group(1))

    return set(funcs.keys()), calls, idents, roots, locs

def bias_interval(c):
    group_bias = (GROUP_BASE - c) / 0.25
    split_bias = (SPLIT_BASE - c) / 0.25
    lo, hi = BIAS_RANGE
    group_bias = max(lo, min(hi, group_bias))
    split_bias = max(lo, min(hi, split_bias))
    if group_bias <= lo and split_bias >= hi:
        return "invariant", None
    return "sensitive", (split_bias, group_bias)

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
        queue = deque([fn])
        component = set()
        while queue:
            cur = queue.popleft()
            if cur in visited:
                continue
            visited.add(cur)
            component.add(cur)
            queue.extend(adj[cur])
        if len(component) > 1:
            clusters.append(component)

    # Precompute internal edges
    all_edges = []
    seen = set()
    for a in functions:
        for b in calls[a]:
            if b not in functions or a == b:
                continue
            pair = tuple(sorted((a, b)))
            if pair in seen:
                continue
            seen.add(pair)
            c = coupling(a, b)
            if c >= 0.15:
                all_edges.append((a, b, c))

    print(f"CLUSTERS (coupling ≥ {CLUSTER_THRESHOLD:.2f})\n")

    for i, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        print(f"CLUSTER {i}")
        print(f"Functions ({len(cluster)}):")
        for fn in sorted(cluster):
            print(f"  {fn}")

        total = sum(func_loc.get(f, 0) for f in cluster)
        by_file = defaultdict(int)
        for f in cluster:
            by_file[func_to_file.get(f, '<unknown>')] += func_loc.get(f, 0)

        if len(by_file) == 1:
            f = next(iter(by_file))
            print(f"Files: all functions in {f}.")
        else:
            print("Files:")
            for f, loc in by_file.items():
                pct = int(round(100 * loc / total)) if total else 0
                print(f"  {f}: {pct}%")
            dom = [f for f, loc in by_file.items() if total and loc / total >= 2/3]
            if dom:
                print(f"{dom[0]} dominates by LOC.")

        internal = [(a, b, c) for (a, b, c) in all_edges if a in cluster and b in cluster]
        internal.sort(key=lambda x: -x[2])
        if internal:
            print("Strong internal edges:")
            for a, b, c in internal[:5]:
                print(f"  {a} ↔ {b}  ({c:.2f})")

        print()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: lua_mod_analyze_cluster_centric_clean.py <path> [...]")
        sys.exit(1)
    analyze([Path(p) for p in sys.argv[1:]])
