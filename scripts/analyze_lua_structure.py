#!/usr/bin/env python3
"""
analyze_lua_structure.py

Structural Lua analyzer.

- Preserves original lua_mod_analyze.py analysis semantics
- Adds lexical scope, delegation, ownership, refactor intent
- Default output: concise declarative sentences
- JSON output only via --json / -j

Analysis → Interpretation → Action are strictly separated.
"""

import sys
import re
import json
import argparse
import statistics
from pathlib import Path
from collections import defaultdict, Counter, deque

# -------------------------
# Frozen thresholds (from original tool)
# -------------------------

CLUSTER_THRESHOLD = 0.35
FRAGILE_MARGIN = 0.10
CONTEXT_SALIENCE_THRESHOLD = 1.5
GLOBAL_CONTEXT_COVERAGE_MAX = 0.25
SMALL_CLUSTER_MAX = 4
LEAF_LOC_MAX = 12

# -------------------------
# Runtime / generic roots (unchanged)
# -------------------------

LUA_RUNTIME_ROOTS = {
    "debug", "string", "table", "math", "io",
    "os", "coroutine", "package", "_G"
}

DEFAULT_GENERIC_CONTEXT_ROOTS = {
    "ctx", "info", "inspectable", "action_def",
    "qt_constants", "defaults", "params", "options"
}

# -------------------------
# Regex
# -------------------------

FUNC_DEF_RE = re.compile(r"\bfunction\s+([a-zA-Z0-9_.:]+)")
FUNC_ARGS_RE = re.compile(r"\bfunction\s+[a-zA-Z0-9_.:]+\s*\(([^)]*)\)")
CALL_RE = re.compile(r"\b([a-zA-Z0-9_.:]+)\s*\(")
IDENT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")
CONTEXT_ROOT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)[\.:][a-zA-Z_][a-zA-Z0-9_]*")
TABLE_ASSIGN_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*\{")
MODULE_ASSIGN_RE = re.compile(r"\bM\.([a-zA-Z_][a-zA-Z0-9_]*)\s*=")

STOPWORDS = {
    "local","function","end","if","then","else","for","do","while",
    "return","nil","true","false","and","or","not"
}

# -------------------------
# Helpers
# -------------------------

def compute_loc(text):
    loc = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        loc += 1
    return loc

def extract_identifiers(text):
    return {i for i in IDENT_RE.findall(text) if i not in STOPWORDS}

def extract_context_roots(text):
    return {m.group(1) for m in CONTEXT_ROOT_RE.finditer(text)}

# -------------------------
# Lua parsing with scope tracking
# -------------------------

def parse_lua(path):
    funcs = {}
    calls = defaultdict(set)
    idents = {}
    roots = {}
    locs = {}
    scopes = {}
    enclosing = {}

    param_roots = set()
    table_roots = set()
    module_roots = set()

    try:
        text = path.read_text(errors="ignore")
    except Exception:
        return funcs, calls, idents, roots, locs, scopes, enclosing, set(), set(), set()

    depth = 0
    active_stack = []

    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()

        m = FUNC_DEF_RE.search(stripped)
        if m:
            name = m.group(1)
            funcs[name] = i
            scopes[name] = "nested" if depth > 0 else "top"
            enclosing[name] = active_stack[-1] if active_stack else None
            active_stack.append(name)
            depth += 1

        if stripped == "end" and depth > 0:
            depth -= 1
            if active_stack:
                active_stack.pop()

        for ma in FUNC_ARGS_RE.finditer(stripped):
            args = [a.strip() for a in ma.group(1).split(",") if a.strip()]
            param_roots.update(args)

        for ta in TABLE_ASSIGN_RE.finditer(stripped):
            table_roots.add(ta.group(1))

        for mm in MODULE_ASSIGN_RE.finditer(stripped):
            module_roots.add(mm.group(1))

    names = list(funcs.keys())
    for idx, name in enumerate(names):
        start = funcs[name]
        end = funcs[names[idx+1]] if idx+1 < len(names) else len(lines)
        body = "\n".join(lines[start:end])

        idents[name] = extract_identifiers(body)
        roots[name] = extract_context_roots(body)
        locs[name] = compute_loc(body)

        for c in CALL_RE.finditer(body):
            calls[name].add(c.group(1))

    return (
        set(funcs.keys()),
        calls,
        idents,
        roots,
        locs,
        scopes,
        enclosing,
        param_roots,
        table_roots,
        module_roots
    )

# -------------------------
# Analysis (original semantics preserved)
# -------------------------

def analyze(paths, generic_roots):
    functions = {}
    calls = defaultdict(set)
    idents = {}
    context_roots = {}
    func_loc = {}
    func_file = {}
    func_scope = {}
    func_enclosing = {}
    global_root_counts = Counter()
    valid_context_roots = set()

    for p in paths:
        files = list(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            (
                fns, c, ids, roots, locs,
                scopes, enclosing,
                param_roots, table_roots, module_roots
            ) = parse_lua(f)

            valid_context_roots |= param_roots | table_roots | module_roots

            for fn in fns:
                functions[fn] = True
                func_file[fn] = f.name
                func_loc[fn] = locs.get(fn, 0)
                func_scope[fn] = scopes.get(fn, "top")
                func_enclosing[fn] = enclosing.get(fn)

                for r in roots.get(fn, []):
                    global_root_counts[r] += 1

            for k,v in c.items():
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
            if coupling(a,b) >= CLUSTER_THRESHOLD:
                adj[a].add(b)
                adj[b].add(a)

    visited = set()
    raw_clusters = []
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
            raw_clusters.append(comp)

    # -------------------------
    # Step 3: exclude nested helpers
    # -------------------------

    clusters = []
    for cluster in raw_clusters:
        filtered = {f for f in cluster if func_scope.get(f) == "top"}
        if len(filtered) > 1:
            clusters.append(filtered)

    # -------------------------
    # Step 4: delegation veneer detection
    # -------------------------

    veneers = {}
    for fn in functions:
        if func_scope.get(fn) != "top":
            continue
        callees = calls.get(fn, set())
        if len(callees) == 1:
            target = next(iter(callees))
            if func_loc.get(fn, 0) <= LEAF_LOC_MAX:
                veneers[fn] = target

    final_clusters = []
    for cluster in clusters:
        non_veneers = {f for f in cluster if f not in veneers}
        if len(non_veneers) > 1:
            final_clusters.append(non_veneers)

    # -------------------------
    # Build cluster analyses
    # -------------------------

    results = []

    for idx, cluster in enumerate(sorted(final_clusters, key=len, reverse=True), 1):
        degree = Counter()
        internal_edges = []
        for a in cluster:
            for b in adj[a]:
                if b in cluster:
                    degree[a] += 1
                    internal_edges.append((a,b,coupling(a,b)))

        central = degree.most_common(1)[0][0]
        hub_strength = degree[central] / max(1, max(degree.values()))

        symmetric_small = (
            len(cluster) <= SMALL_CLUSTER_MAX and
            max(fanout.get(f,0) for f in cluster) <= 2
        )

        if symmetric_small:
            cluster_type = "Primitive"
        elif hub_strength >= 0.4:
            cluster_type = "Algorithm"
        else:
            cluster_type = "Model"

        # Context salience (unchanged logic)
        cluster_root_counts = Counter()
        suppressed = []
        eligible = {}

        for fn in cluster:
            for r in context_roots.get(fn, []):
                cluster_root_counts[r] += 1

        for r, cnt in cluster_root_counts.items():
            if r in LUA_RUNTIME_ROOTS:
                suppressed.append((r, "lua runtime"))
                continue
            if r in generic_roots:
                suppressed.append((r, "generic scaffolding"))
                continue
            if r not in valid_context_roots:
                suppressed.append((r, "field-only"))
                continue
            users = [fn for fn in cluster if r in context_roots.get(fn, set()) and fn != central]
            if len(users) < 2:
                suppressed.append((r, "hub-only or single-use"))
                continue
            global_cov = global_root_counts[r] / total_functions
            if global_cov > GLOBAL_CONTEXT_COVERAGE_MAX:
                suppressed.append((r, "high global coverage"))
                continue
            eligible[r] = cnt

        salient_root = None
        best_salience = 0.0
        for r, cnt in eligible.items():
            cluster_freq = cnt / len(cluster)
            global_freq = global_root_counts[r] / total_functions
            if global_freq > 0:
                salience = cluster_freq / global_freq
                if salience > best_salience:
                    best_salience = salience
                    salient_root = r

        # File distribution
        total_loc = sum(func_loc.get(f,0) for f in cluster)
        by_file = Counter()
        for f in cluster:
            by_file[func_file.get(f)] += func_loc.get(f,0)

        # Ownership (Step 5 revised)
        if len(by_file) == 1:
            ownership = ("InternalComponent", next(iter(by_file)))
        else:
            dom_file, dom_loc = by_file.most_common(1)[0]
            if dom_loc / total_loc >= 0.67:
                ownership = ("InternalComponent", dom_file)
            else:
                ownership = ("RecommendNewModule", "<unassigned>")

        # Responsibility summary
        role = (
            "coordinates related operations"
            if cluster_type == "Algorithm"
            else "manages shared state"
            if cluster_type == "Model"
            else "implements atomic behavior"
        )

        responsibility = {
            "kind": "algorithmic" if cluster_type == "Algorithm"
                    else "stateful" if cluster_type == "Model"
                    else "mixed",
            "central": central,
            "hub": "high" if hub_strength >= 0.6
                   else "medium" if hub_strength >= 0.4
                   else "low",
            "salient_root": salient_root,
            "role": role
        }

        # Refactor intent (Step 6)
        if cluster_type == "Algorithm" and not symmetric_small:
            refactor = (
                "RecommendRefactor",
                "Cluster is organized around a coordinating function; responsibilities can be decomposed with low structural risk.",
                "Define named helper functions and call them from the central function."
            )
        else:
            refactor = (
                "NoRefactor",
                "Cluster is structurally stable.",
                None
            )

        results.append({
            "id": idx,
            "functions": sorted(cluster),
            "type": cluster_type,
            "ownership": ownership,
            "responsibility": responsibility,
            "refactor": refactor,
            "files": {
                f: round(100 * l / total_loc)
                for f,l in by_file.items()
            }
        })

    return results

# -------------------------
# Output
# -------------------------

def print_text(results):
    for r in results:
        print(f"CLUSTER {r['id']}")
        print(f"Type: {r['type']}")
        print()
        resp = r["responsibility"]
        print("Responsibility:")
        print(f"{resp['central']} is the structural center.")
        if resp["salient_root"]:
            print(f"Cohesion is driven by shared '{resp['salient_root']}' context usage.")
        print(f"This cluster {resp['role']}.")
        print()
        own, mod = r["ownership"]
        print("Ownership:")
        print(f"{own} of {mod}.")
        print()
        rec, rat, act = r["refactor"]
        print("Refactor intent:")
        print(rat)
        if act:
            print(act)
        print()
        print("Files:")
        for f,p in r["files"].items():
            print(f"{f}: {p}%")
        print()
        print("Functions:")
        for fn in r["functions"]:
            print(fn)
        print()

def print_json(results, paths):
    out = {
        "analysis_version": "1.0",
        "scope": {
            "root_paths": [str(p) for p in paths],
            "language": "lua"
        },
        "clusters": results
    }
    print(json.dumps(out, indent=2))

# -------------------------
# Entry
# -------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", "-j", action="store_true")
    ap.add_argument("--generic-roots", default="")
    args = ap.parse_args()

    generic_roots = set(DEFAULT_GENERIC_CONTEXT_ROOTS)
    if args.generic_roots:
        generic_roots |= {r.strip() for r in args.generic_roots.split(",") if r.strip()}

    results = analyze([Path(p) for p in args.paths], generic_roots)

    if args.json:
        print_json(results, args.paths)
    else:
        print_text(results)

if __name__ == "__main__":
    main()
