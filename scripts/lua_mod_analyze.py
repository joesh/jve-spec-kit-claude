#!/usr/bin/env python3
# lua_mod_analyze_cluster_centric_sentences_fragile_v9.py
#
# Changes from v8:
# - Excludes Lua runtime / standard-library roots from explanatory attribution
#   (debug, string, table, math, etc.)
# - Still uses rarity-weighted + global-coverage-gated salience
# - No changes to clustering or coupling

import sys
import re
import statistics
from pathlib import Path
from collections import defaultdict, Counter, deque

CLUSTER_THRESHOLD = 0.35
FRAGILE_MARGIN = 0.10
CONTEXT_SALIENCE_THRESHOLD = 1.5
GLOBAL_CONTEXT_COVERAGE_MAX = 0.25

# Lua runtime / standard library tables: never architectural carriers
LUA_RUNTIME_ROOTS = {
    "debug", "string", "table", "math", "io",
    "os", "coroutine", "package", "_G"
}

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
        return set(), calls, idents, roots, locs

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
    global_root_counts = Counter()

    for p in paths:
        files = list(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            fns, c, ids, roots, locs = parse_lua(f)
            for fn in fns:
                functions[fn] = f
                func_to_file[fn] = f.name
                func_loc[fn] = locs.get(fn, 0)
                for r in roots.get(fn, []):
                    global_root_counts[r] += 1
            for k, v in c.items():
                calls[k].update(v)
            idents.update(ids)
            context_roots.update(roots)

    total_functions = max(1, len(functions))
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

        print(f"CLUSTER {i}")
        print(f"Functions ({len(cluster)}):")
        for fn in sorted(cluster):
            print(f"  {fn}")

        degree = Counter()
        for a,b,_ in internal:
            degree[a] += 1
            degree[b] += 1
        central = degree.most_common(1)[0][0] if degree else sorted(cluster)[0]

        cluster_root_counts = Counter()
        for fn in cluster:
            for r in context_roots.get(fn, []):
                cluster_root_counts[r] += 1

        salient_root = None
        best_salience = 0.0
        for r, cnt in cluster_root_counts.items():
            if r in LUA_RUNTIME_ROOTS:
                continue
            global_cov = global_root_counts[r] / total_functions
            if global_cov > GLOBAL_CONTEXT_COVERAGE_MAX:
                continue
            cluster_freq = cnt / len(cluster)
            global_freq = global_root_counts[r] / total_functions
            if global_freq > 0:
                salience = cluster_freq / global_freq
                if salience > best_salience:
                    best_salience = salience
                    salient_root = r

        total = sum(func_loc.get(f,0) for f in cluster)
        by_file = Counter()
        for f in cluster:
            by_file[func_to_file.get(f,'<unknown>')] += func_loc.get(f,0)
        dom_file, dom_loc = by_file.most_common(1)[0]
        dom_pct = int(round(100 * dom_loc / total)) if total else 0

        print("Analysis:")
        if salient_root and best_salience >= CONTEXT_SALIENCE_THRESHOLD:
            print(f"This cluster is organized around {central}, with cohesion driven primarily by shared '{salient_root}' context usage.")
        else:
            print(f"This cluster is organized around {central}, with cohesion driven primarily by internal call structure rather than shared context.")

        if dom_pct >= 67:
            print(f"Most logic resides in {dom_file} ({dom_pct}% of cluster LOC), indicating an existing structural center.")
        else:
            files = ', '.join(by_file.keys())
            print(f"Logic is split across {files}, with no single file fully dominating the cluster.")

        if internal:
            weights = [c for _,_,c in internal]
            median = statistics.median(weights)
            fragile = [(a,b,c) for (a,b,c) in internal
                       if c < median or abs(c - CLUSTER_THRESHOLD) <= FRAGILE_MARGIN]

            if fragile:
                funcs = Counter()
                for a,b,_ in fragile:
                    funcs[a] += 1
                    funcs[b] += 1
                boundary = funcs.most_common(1)[0][0]

                if boundary == central:
                    print(
                        f"{boundary} is the structural hub of this cluster; weaker connections here suggest "
                        f"an opportunity to decompose responsibilities inside the function rather than extract it."
                    )
                else:
                    frag_neighbors = [
                        (b if a == boundary else a)
                        for (a,b,_) in fragile
                        if a == boundary or b == boundary
                    ]
                    by_root = Counter()
                    for n in frag_neighbors:
                        for r in context_roots.get(n, []):
                            if r in LUA_RUNTIME_ROOTS:
                                continue
                            by_root[r] += 1
                    if by_root:
                        root = by_root.most_common(1)[0][0]
                        print(
                            f"Cohesion weakens at the boundary involving {boundary}, "
                            f"suggesting it primarily mediates '{root}' behavior and could be extracted "
                            f"along that responsibility with low structural cost."
                        )
                    else:
                        print(
                            f"Cohesion weakens at the boundary involving {boundary}, "
                            f"suggesting this function could be extracted alongside its immediate collaborators "
                            f"with relatively low structural cost."
                        )

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
        print("usage: lua_mod_analyze_cluster_centric_sentences_fragile_v9.py <path> [...]")
        sys.exit(1)
    analyze([Path(p) for p in sys.argv[1:]])
