#!/usr/bin/env python3

import sys
import re
import json
import argparse
import statistics
from pathlib import Path
from collections import defaultdict, Counter, deque

try:
    import networkx as nx
    HAS_NETWORKX = True
except ImportError:
    HAS_NETWORKX = False

# -------------------------
# Thresholds (unchanged)
# -------------------------

CLUSTER_THRESHOLD = 0.35
FRAGILE_MARGIN = 0.10
CONTEXT_SALIENCE_THRESHOLD = 1.5
GLOBAL_CONTEXT_COVERAGE_MAX = 0.25
SMALL_CLUSTER_MAX = 4
LEAF_LOC_MAX = 12
BETWEENNESS_THRESHOLD = 0.06  # Filter edges with betweenness > this (bridge edges)

# -------------------------
# Runtime / generic roots
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
# Lua parsing with scope
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

    text = path.read_text(errors="ignore")
    lines = text.splitlines()

    depth = 0
    active_stack = []

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
# Analysis
# -------------------------


# -------------------------
# Cluster explanation
# -------------------------

def _cluster_internal_edges(cluster, all_edges):
    internal = [(a, b, c) for (a, b, c) in all_edges if a in cluster and b in cluster]
    internal.sort(key=lambda x: -x[2])
    return internal

def _central_function(cluster, internal):
    degree = Counter()
    for a, b, _ in internal:
        degree[a] += 1
        degree[b] += 1
    central = degree.most_common(1)[0][0] if degree else sorted(cluster)[0]
    return central, degree

def _salient_context_root(cluster, context_roots, valid_context_roots, generic_roots, global_root_counts, total_functions):
    cluster_root_counts = Counter()
    for fn in cluster:
        for r in context_roots.get(fn, set()):
            cluster_root_counts[r] += 1

    eligible_roots = {}
    suppressed = []

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

        users = [f for f in cluster if r in context_roots.get(f, set())]
        if len(users) < 2:
            suppressed.append((r, "hub-only or single-use"))
            continue

        global_cov = global_root_counts[r] / max(1, total_functions)
        if global_cov > GLOBAL_CONTEXT_COVERAGE_MAX:
            suppressed.append((r, "high global coverage"))
            continue

        eligible_roots[r] = cnt

    salient_root = None
    best_salience = 0.0
    for r, cnt in eligible_roots.items():
        cluster_freq = cnt / max(1, len(cluster))
        global_freq = global_root_counts[r] / max(1, total_functions)
        if global_freq <= 0:
            continue
        salience = cluster_freq / global_freq
        if salience > best_salience:
            best_salience = salience
            salient_root = r

    return salient_root, best_salience, suppressed

def _fragile_edges(internal):
    if not internal:
        return [], None
    weights = [c for _, _, c in internal]
    median = statistics.median(weights) if weights else 0.0
    fragile = [(a, b, c) for (a, b, c) in internal
               if (c < median) or (abs(c - CLUSTER_THRESHOLD) <= FRAGILE_MARGIN)]
    funcs = Counter()
    for a, b, _ in fragile:
        funcs[a] += 1
        funcs[b] += 1
    boundary = funcs.most_common(1)[0][0] if funcs else None
    return fragile, boundary

def _analysis_for_cluster(cluster, internal, central, degree, fanout, context_roots,
                         valid_context_roots, generic_roots, global_root_counts, total_functions,
                         func_loc, by_file, total_loc, dom_file, dom_pct,
                         explain_suppressed):
    sentences = []

    salient_root, salience, suppressed = _salient_context_root(
        cluster, context_roots, valid_context_roots, generic_roots, global_root_counts, total_functions
    )

    symmetric_small = (
        len(cluster) <= SMALL_CLUSTER_MAX and
        max(fanout.get(f, 0) for f in cluster) <= 2
    )
    hub_strength = 0.0
    if degree:
        hub_strength = degree[central] / max(1, max(degree.values()))
    orchestration = (hub_strength >= 0.4 and not symmetric_small)

    if orchestration:
        sentences.append(
            f"This cluster is organized around {central}, with cohesion driven by orchestration and coordination logic rather than a shared domain abstraction."
        )
    elif salient_root and salience >= CONTEXT_SALIENCE_THRESHOLD:
        sentences.append(
            f"This cluster is organized around {central}, with cohesion driven primarily by shared '{salient_root}' context usage."
        )
    else:
        sentences.append(
            f"This cluster is organized around {central}, with cohesion driven by shared local interactions rather than a single dominant context root."
        )

    if dom_file and dom_file != "<unknown>":
        sentences.append(
            f"Most logic resides in {dom_file} ({dom_pct}% of cluster LOC), indicating an existing structural center."
        )

    fragile, boundary = _fragile_edges(internal)

    if fragile and boundary:
        sentences.append(
            f"Fragile edges concentrate around {boundary}, which is the lowest-structural-cost seam to peel responsibilities away from the cluster."
        )

        if boundary == central:
            sentences.append(
                f"{central} is the structural hub of this cluster; instead of extracting {central} itself, split responsibilities inside {central} using (a) module-scope helper functions called by {central}, and (b) small nested local helpers for one-off substeps."
            )
        else:
            sentences.append(
                f"A first extraction candidate is the responsibility centered on {boundary}; it touches the rest of the cluster mostly through weak ties, so it is a good candidate to separate and reattach with low risk."
            )

        funcs = Counter()
        for a, b, _ in fragile:
            funcs[a] += 1
            funcs[b] += 1
        boundary_candidates = [f for f, _ in funcs.most_common(5)]

        helpers = [f for f in boundary_candidates if f != central and func_loc.get(f, 0) > LEAF_LOC_MAX]
        if boundary == central and helpers:
            names = ", ".join(helpers[:3])
            sentences.append(
                f"Likely helper extraction targets include {names}, which sit on the weakest boundaries around {central}."
            )
    else:
        boundary_candidates = []

    return {
        "sentences": sentences,
        "central": central,
        "salient_root": salient_root,
        "salience": round(float(salience), 3),
        "orchestration": bool(orchestration),
        "fragile_edges": [(a, b, round(float(c), 3)) for a, b, c in fragile[:12]],
        "boundary_candidates": boundary_candidates,
        "suppressed_roots": suppressed if explain_suppressed else [],
    }

def analyze(paths, generic_roots, explain_suppressed=False):
    functions = {}
    calls = defaultdict(set)
    idents = {}
    context_roots = {}
    func_loc = {}
    func_file = {}
    func_scope = {}
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

                for r in roots.get(fn, []):
                    global_root_counts[r] += 1

            for k,v in c.items():
                calls[k].update(v)

            idents.update(ids)
            context_roots.update(roots)

    total_functions = max(1, len(functions))
    fanout = {fn: len(calls.get(fn, [])) for fn in functions}

    # FIX 2: delegation veneers detected EARLY (graph-opaque)
    veneers = {}
    for fn in functions:
        if func_scope.get(fn) != "top":
            continue
        callees = calls.get(fn, set())
        if len(callees) == 1 and func_loc.get(fn, 0) <= LEAF_LOC_MAX:
            veneers[fn] = next(iter(callees))

    structural_functions = {fn for fn in functions if fn not in veneers}

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


    # Build edges and adjacency
    MIN_EDGE = 0.15
    all_edges = []
    seen = set()
    adj = defaultdict(set)
    for a in structural_functions:
        for b in calls.get(a, []):
            if b not in structural_functions or a == b:
                continue
            pair = tuple(sorted((a, b)))
            if pair in seen:
                continue
            seen.add(pair)
            c = coupling(a, b)
            if c >= MIN_EDGE:
                all_edges.append((a, b, c))
            if c >= CLUSTER_THRESHOLD:
                adj[a].add(b)
                adj[b].add(a)

    # Apply community detection if NetworkX available
    if HAS_NETWORKX:
        # Build graph with coupling weights
        G = nx.Graph()
        for a in structural_functions:
            for b in adj[a]:
                if a < b:  # Add each edge once
                    # Find coupling score for this edge
                    edge_weight = coupling(a, b)
                    G.add_edge(a, b, weight=edge_weight)

        # Use Louvain community detection
        if len(G.edges()) > 0:
            print(f"# Running Louvain community detection on {len(G.nodes())} nodes, {len(G.edges())} edges...", file=sys.stderr)

            try:
                from networkx.algorithms import community as nx_comm

                # Louvain method - maximizes modularity
                communities = nx_comm.louvain_communities(G, weight='weight', resolution=1.0, seed=42)

                print(f"# Found {len(communities)} communities via Louvain", file=sys.stderr)

                # Convert to cluster format
                clusters = []
                for i, comm in enumerate(communities):
                    if len(comm) > 1:  # Only keep multi-function clusters
                        clusters.append(comm)
                        print(f"#   Community {i+1}: {len(comm)} functions", file=sys.stderr)

            except ImportError:
                print("# NetworkX community module not available, falling back to BFS", file=sys.stderr)
                # Fallback to BFS
                visited = set()
                clusters = []
                for fn in structural_functions:
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
    else:
        # No NetworkX - use simple BFS
        visited = set()
        clusters = []
        for fn in structural_functions:
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

    results = []
    for idx, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        degree = Counter()
        for a in cluster:
            for b in adj[a]:
                if b in cluster:
                    degree[a] += 1

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

        by_file = Counter()
        total_loc = 0
        for f in cluster:
            l = func_loc.get(f, 0)
            by_file[func_file.get(f)] += l
            total_loc += l

        if len(by_file) == 1:
            ownership = ("InternalComponent", next(iter(by_file)))
        else:
            dom_file, dom_loc = by_file.most_common(1)[0]
            if dom_loc / max(1, total_loc) >= 0.67:
                ownership = ("InternalComponent", dom_file)
            else:
                ownership = ("RecommendNewModule", "<unassigned>")

        internal = _cluster_internal_edges(cluster, all_edges)

        central, degree = _central_function(cluster, internal)

        dom_file, dom_loc = by_file.most_common(1)[0] if by_file else ("<unknown>", 0)

        dom_pct = int(round(100 * dom_loc / max(1, total_loc)))

        analysis = _analysis_for_cluster(

            cluster=cluster,

            internal=internal,

            central=central,

            degree=degree,

            fanout=fanout,

            context_roots=context_roots,

            valid_context_roots=valid_context_roots,

            generic_roots=generic_roots,

            global_root_counts=global_root_counts,

            total_functions=total_functions,

            func_loc=func_loc,

            by_file=by_file,

            total_loc=total_loc,

            dom_file=dom_file,

            dom_pct=dom_pct,

            explain_suppressed=explain_suppressed,

        )


        results.append({
            "id": idx,
            "type": cluster_type,
            "ownership": ownership,
            "analysis": analysis,
            "functions": sorted(cluster),
            "files": {
                f: round(100 * l / max(1, total_loc))
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
        own, mod = r["ownership"]
        print(f"{own} of {mod}.")
        print()

        print("Files:")
        for f, p in r["files"].items():
            print(f"{f}: {p}%")
        print()

        print("Functions:")
        for fn in r["functions"]:
            print(fn)
        print()

        analysis = r.get("analysis") or {}
        sentences = analysis.get("sentences") or []
        if sentences:
            print("Analysis:")
            for s in sentences:
                print(s)
            print()

        fragile = analysis.get("fragile_edges") or []
        if fragile:
            parts = [f"{a} ↔ {b} ({c:.2f})" for a, b, c in fragile[:8]]
            print("Fragile edges: " + ", ".join(parts) + ".")
            print()

        bc = analysis.get("boundary_candidates") or []
        if bc:
            print("Boundary candidates: " + ", ".join(bc[:5]) + ".")
            print()

        suppressed = analysis.get("suppressed_roots") or []
        if suppressed:
            items = ", ".join([f"{r} ({why})" for r, why in suppressed[:12]])
            print("Suppressed context roots: " + items + ".")
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
    ap.add_argument("--explain-suppressed", action="store_true")
    args = ap.parse_args()

    generic_roots = set(DEFAULT_GENERIC_CONTEXT_ROOTS)
    if args.generic_roots:
        generic_roots |= {r.strip() for r in args.generic_roots.split(",") if r.strip()}

    results = analyze([Path(p) for p in args.paths], generic_roots, explain_suppressed=args.explain_suppressed)

    if args.json:
        print_json(results, args.paths)
    else:
        print_text(results)

if __name__ == "__main__":
    main()
