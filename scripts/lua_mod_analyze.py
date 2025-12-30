#!/usr/bin/env python3
# lua_mod_analyze.py v2 – coupling with shared-identifier attraction

import sys
import argparse
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
CONTEXT_ROOT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)[\.:][a-zA-Z_][a-zA-Z0-9_]*")
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

def extract_context_roots(text):
    return {m.group(1) for m in CONTEXT_ROOT_RE.finditer(text)}

def extract_identifiers(text):
    return {i for i in IDENT_RE.findall(text) if i not in STOPWORDS}


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
    context_roots = {}
    roots = {}
    try:
        text = path.read_text()
    except Exception:
        return {}, calls, {}, "", {}
    for m in FUNC_DEF_RE.finditer(text):
        funcs[m.group(1)] = m.end()
    names = list(funcs.keys())
    ranges = []
    for i, name in enumerate(names):
        start = funcs[name]
        end = funcs[names[i+1]] if i+1 < len(names) else len(text)
        ranges.append((name, start, end))
    locs = {}
    for name, start, end in ranges:
        body = text[start:end]
        idents[name] = extract_identifiers(body)
        locs[name] = compute_loc(body)
        roots[name] = extract_context_roots(body)
        for m in CALL_RE.finditer(body):
            calls[name].add(m.group(1))
    return set(funcs.keys()), calls, idents, roots, text, locs

def bias_interval(c):
    group_bias = (GROUP_BASE - c) / 0.25
    split_bias = (SPLIT_BASE - c) / 0.25
    lo, hi = BIAS_RANGE
    group_bias = max(lo, min(hi, group_bias))
    split_bias = max(lo, min(hi, split_bias))
    if group_bias <= lo and split_bias >= hi:
        return "invariant", None
    return "sensitive", (split_bias, group_bias)

def analyze(paths, details=False):
    functions = {}

    func_loc = {}
    func_to_file = {}
    func_to_folder = {}

    calls = defaultdict(set)
    idents = {}
    context_roots = {}
    roots = {}
    fanout = {}
    for p in paths:
        files = list(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            fns, c, ids, roots, _, locs = parse_lua(f)
            for fn in fns:
                functions[fn] = f
                func_to_file[fn] = f.name
                func_to_folder[fn] = f.parent.name
                func_loc[fn] = locs.get(fn, 0)
            for k, v in c.items():
                calls[k].update(v)
            idents.update(ids)
            context_roots.update(roots)
    for fn in functions:
        fanout[fn] = len(calls.get(fn, []))
    
    def coupling(a, b):
        score = 0.0

        # Context-root overlap (primary signal)
        shared_roots = context_roots.get(a, set()) & context_roots.get(b, set())
        if shared_roots:
            score += min(0.8, 0.4 + 0.2 * len(shared_roots))

        # Identifier overlap (weak signal)
        shared = idents.get(a,set()) & idents.get(b,set())
        if len(shared) >= 3:
            score += min(0.3, len(shared) * 0.03)

        # Call signal (supporting)
        if b in calls[a]:
            score += 0.5 / max(1, fanout[a])

        # Fan-out penalty
        score -= min(0.5, fanout[b] * 0.03)

        # Relaxed directional penalty (UI-friendly)
        if b in calls[a] and a not in calls[b]:
            score -= 0.05

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


    
    # STEP 2: COMPARE
    DOMINANCE_THRESHOLD = 2/3
    UNDERSIZED_THRESHOLD = 0.10

    for i, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        total_loc = sum(func_loc.get(fn, 0) for fn in cluster)
        print(f"COMPARE Cluster {i}:")

        # Files
        by_file = defaultdict(list)
        for fn in cluster:
            by_file[func_to_file.get(fn, '<unknown>')].append(fn)
        if len(by_file) == 1:
            f = next(iter(by_file))
            print(f"Files: all cluster functions are in {f}.")
        else:
            shares = {
                f: sum(func_loc[fn] for fn in fns)/total_loc
                for f, fns in by_file.items()
            }
            print(f"Files: cluster spans {', '.join(by_file.keys())}.")
            dom = [f for f,s in shares.items() if s >= DOMINANCE_THRESHOLD]
            if dom:
                f = dom[0]
                print(f"{f} dominates, containing {int(round(shares[f]*100))}% of cluster LOC.")
            else:
                parts = [f"{f} contains {int(round(shares[f]*100))}%" for f in shares]
                print('; '.join(parts) + '.')
            undersized = [f for f,s in shares.items() if s < UNDERSIZED_THRESHOLD]
            if undersized:
                print(f"{undersized[0]} is undersized within this cluster.")

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
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--details", action="store_true")
    args = parser.parse_args()
    analyze([Path(p) for p in args.paths], details=args.details)