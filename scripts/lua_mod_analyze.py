#!/usr/bin/env python3
# lua_mod_analyze.py v2 – coupling with shared-identifier attraction

import sys
import re
import math
from pathlib import Path
from collections import defaultdict

GROUP_BASE = 0.65
SPLIT_BASE = 0.35
BIAS_RANGE = (-1.0, 1.0)
CLUSTER_THRESHOLD = 0.35


HEADER_RE = re.compile(r"--\s*@(?P<key>\w+)\s+(?P<val>.+)")
FUNC_DEF_RE = re.compile(r"\bfunction\s+([a-zA-Z0-9_.:]+)")
CALL_RE = re.compile(r"\b([a-zA-Z0-9_.:]+)\s*\(")
IDENT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")

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

def parse_lua(path):
    funcs = {}
    calls = defaultdict(set)
    idents = {}
    try:
        text = path.read_text()
    except Exception:
        return {}, calls, {}, ""
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
        for m in CALL_RE.finditer(body):
            calls[name].add(m.group(1))
    return set(funcs.keys()), calls, idents, text

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
    fanout = {}
    for p in paths:
        files = list(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            fns, c, ids, _ = parse_lua(f)
            for fn in fns:
                functions[fn] = f
            for k, v in c.items():
                calls[k].update(v)
            idents.update(ids)
    for fn in functions:
        fanout[fn] = len(calls.get(fn, []))
    def coupling(a, b):
        score = 0.0
        if b in calls[a]:
            score += 1.0 / max(1, fanout[a])
        shared = idents.get(a,set()) & idents.get(b,set())
        if len(shared) >= 3:
            score += min(0.6, len(shared) * 0.05)
        score -= min(0.6, fanout[b] * 0.03)
        if b in calls[a] and a not in calls[b]:
            score -= 0.3
        return max(0.0, min(1.0, score))
    
    from collections import deque

    # Build adjacency for clustering
    adj = defaultdict(set)

    for a in functions:
        for b in calls[a]:
            if b not in functions or a == b:
                continue
            c = coupling(a, b)
            if c >= CLUSTER_THRESHOLD:
                adj[a].add(b)
                adj[b].add(a)

    # Find connected components
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

    print("CLUSTERS (coupling ≥ {:.2f})\n".format(CLUSTER_THRESHOLD))

    for i, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        print(f"Cluster {i} ({len(cluster)} functions):")
        for fn in sorted(cluster):
            print(f"  {fn}")
        print()


    print("MODULE ANALYSIS REPORT\n")
    seen = set()
    for a in functions:
        for b in calls[a]:
            if b not in functions:
                continue
            pair = tuple(sorted((a,b)))
            if pair in seen:
                continue
            seen.add(pair)

            # skip self-pairs
            if a == b:
                continue

            c = coupling(a,b)
            # ignore very weak couplings
            if c < 0.15:
                continue

            kind, interval = bias_interval(c)
            if kind == "sensitive":
                lo, hi = interval
                print(f"{a} ↔ {b}  coupling={c:.2f}  bias-sensitive [{lo:.2f},{hi:.2f}]")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: lua_mod_analyze.py <path> [...]")
        sys.exit(1)
    analyze([Path(p) for p in sys.argv[1:]])
