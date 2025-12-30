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

def tokenize_identifier(name):
    """
    Tokenize function name for semantic similarity.

    Examples:
        "M.start_inline_rename" -> {"M", "start", "inline", "rename"}
        "create_bin_in_root" -> {"create", "bin", "in", "root"}
        "finalizePendingRename" -> {"finalize", "pending", "rename"} (camelCase)
    """
    # Remove common prefixes
    name = name.replace("M.", "").replace("_", " ").replace(".", " ").replace(":", " ")

    # Split camelCase: "finalizePending" -> "finalize Pending"
    name = re.sub(r'([a-z])([A-Z])', r'\1 \2', name)

    # Extract words
    tokens = {w.lower() for w in name.split() if w and w.lower() not in STOPWORDS}
    return tokens

def semantic_similarity(name_a, name_b):
    """
    Calculate semantic similarity between function names using Jaccard similarity.

    Returns value in [0.0, 1.0] where:
    - 1.0 = identical token sets
    - 0.0 = no common tokens
    """
    tokens_a = tokenize_identifier(name_a)
    tokens_b = tokenize_identifier(name_b)

    if not tokens_a or not tokens_b:
        return 0.0

    intersection = len(tokens_a & tokens_b)
    union = len(tokens_a | tokens_b)

    return intersection / union if union > 0 else 0.0

def load_call_graph(path):
    """Load global call graph database from JSON."""
    with open(path) as f:
        data = json.load(f)
    return data.get('functions', {})

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

    # Extract function bodies by parsing function/end pairs
    for name in funcs.keys():
        start_line = funcs[name]

        # Find matching 'end' by counting depth
        depth = 1  # We've seen one 'function'
        end_line = len(lines)  # Default to EOF

        for i in range(start_line + 1, len(lines)):
            stripped = lines[i].strip()

            # Count 'function' keywords (increases depth)
            if 'function' in stripped:
                # Check if it's a whole word
                for m in re.finditer(r'\bfunction\b', stripped):
                    depth += 1

            # Count 'end' keywords (decreases depth)
            if stripped.startswith('end') or ' end' in stripped or '\tend' in stripped:
                # Check if it's a whole word
                for m in re.finditer(r'\bend\b', stripped):
                    depth -= 1
                    if depth == 0:
                        end_line = i
                        break

            if depth == 0:
                break

        body = "\n".join(lines[start_line:end_line])

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
                         explain_suppressed, call_graph=None):
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

    # Initialize quality tracking
    has_quality_issues = False
    quality_issues = []

    if orchestration:
        sentences.append(f"This cluster implements the algorithm described in {central}.")

        # Collect quality issues for later (we'll report them after file location)
        central_loc = func_loc.get(central, 0)
        central_fanout = fanout.get(central, 0)
        central_nested = 0
        if call_graph and central in call_graph:
            central_nested = call_graph[central].get('nested_functions', 0)

        # Issue 1: High LOC per call ratio (contains low-level code mixed with orchestration)
        if central_fanout > 0:
            loc_per_call = central_loc / central_fanout
            if loc_per_call > 15:
                quality_issues.append(f"contains substantial low-level implementation ({central_loc} LOC, {central_fanout} calls)")

        # Issue 2: Excessive nested functions (hard to read, should be extracted)
        if central_nested >= 6:  # Lowered threshold - even 6 nested functions is quite bad
            quality_issues.append(f"defines {central_nested} nested functions")

        # Issue 3: Very high LOC even if calls are many (just too big overall)
        # Only check LOC if we have valid data (> 0)
        if central_loc > 80:
            quality_issues.append(f"spans {central_loc} LOC")

        # Store quality issues for later (after file location)
        has_quality_issues = len(quality_issues) > 0
    elif salient_root and salience >= CONTEXT_SALIENCE_THRESHOLD:
        sentences.append(
            f"This cluster is organized around {central}, with cohesion driven primarily by shared '{salient_root}' context usage."
        )
    else:
        sentences.append(
            f"This cluster is organized around {central}, with cohesion driven by shared local interactions rather than a single dominant context root."
        )

    # File location (immediately after cluster identity)
    if dom_file and dom_file != "<unknown>":
        if dom_pct == 100:
            sentences.append(f"All logic resides in {dom_file}.")
        else:
            sentences.append(f"{dom_pct}% of logic resides in {dom_file}.")

    # Quality issues (after file location, before structural analysis)
    if orchestration and has_quality_issues:
        quality_str = ", ".join(quality_issues)
        sentences.append(f"The hub function {quality_str}, making it difficult to read and test.")

    fragile, boundary = _fragile_edges(internal)

    if fragile and boundary:
        sentences.append(
            f"Fragile edges concentrate around {boundary}, the lowest-cost extraction seam."
        )

        if boundary == central:
            # Build refactoring recommendation based on quality issues
            if has_quality_issues:
                sentences.append(
                    f"The hub is the structural center; refactor by extracting logic into (a) module-scope helper functions, and (b) nested local helpers for one-off substeps."
                )
            else:
                sentences.append(
                    f"{central} is the structural hub; instead of extracting it, split responsibilities inside using (a) module-scope helpers, and (b) nested local helpers for one-off substeps."
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

def analyze(paths, generic_roots, explain_suppressed=False, call_graph=None):
    """
    Analyze Lua codebase and identify clusters.

    Args:
        paths: List of paths to scan
        generic_roots: Set of generic context roots to filter
        explain_suppressed: Whether to show suppressed context roots
        call_graph: Optional dict from load_call_graph() for utility filtering
    """
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

    # Filter utilities using global call graph (if provided)
    utilities = set()
    utility_details = []
    if call_graph:
        print(f"# Filtering utilities using global call graph...", file=sys.stderr)
        for fn in functions:
            if fn in call_graph and call_graph[fn].get('is_utility', False):
                utilities.add(fn)
                fanin_val = call_graph[fn].get('fanin', 0)
                files_calling = call_graph[fn].get('files_calling', 0)
                utility_details.append((fn, fanin_val, files_calling))

        print(f"# Identified {len(utilities)} utilities to exclude from clustering", file=sys.stderr)

    structural_functions = {fn for fn in functions if fn not in veneers and fn not in utilities}

    def coupling(a, b):
        score = 0.0

        # Structural coupling (existing logic)
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

        # Semantic coupling (NEW: name similarity)
        name_sim = semantic_similarity(a, b)
        if name_sim > 0:
            score += name_sim * 0.3  # Weight semantic signal

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

    # Calculate fanin and callers
    # Use global data from call graph if available, otherwise calculate locally
    if call_graph:
        fanin = {fn: call_graph.get(fn, {}).get('fanin', 0) for fn in structural_functions}
        # Use global callers from call graph (but filter to structural_functions)
        callers = defaultdict(set)
        for fn in structural_functions:
            if fn in call_graph:
                global_callers = set(call_graph[fn].get('callers', []))
                # Only include callers that are in structural_functions
                callers[fn] = global_callers & structural_functions
    else:
        # Local calculation (for when call_graph not provided)
        fanin = Counter()
        callers = defaultdict(set)
        for caller in structural_functions:
            for callee in calls.get(caller, []):
                if callee in structural_functions:
                    fanin[callee] += 1
                    callers[callee].add(caller)

    print(f"# Building call tree ownership clusters...", file=sys.stderr)

    # Identify orchestrators (high fanout - call many helpers)
    ORCHESTRATOR_THRESHOLD = 3
    orchestrators = {fn for fn in structural_functions if len(calls.get(fn, [])) >= ORCHESTRATOR_THRESHOLD}
    print(f"# Found {len(orchestrators)} orchestrators (fanout >= {ORCHESTRATOR_THRESHOLD})", file=sys.stderr)

    # Build clusters around orchestrators using call tree ownership
    clusters = []
    claimed = set()  # Track which functions have been claimed by a cluster

    # Sort orchestrators by fanout (descending) to process larger trees first
    orchestrators_sorted = sorted(orchestrators, key=lambda f: len(calls.get(f, [])), reverse=True)

    for orch in orchestrators_sorted:
        if orch in claimed:
            continue  # Already part of another cluster

        cluster = {orch}
        claimed.add(orch)

        # Recursively add exclusive helpers (fanin=1, only called by this orchestrator)
        def add_exclusive_subtree(fn, depth=0):
            for callee in calls.get(fn, []):
                if callee not in structural_functions:
                    continue
                if callee in claimed:
                    continue

                # Check if this is an exclusive helper (only called by functions in this cluster)
                callee_fanin = fanin.get(callee, 0)
                callee_callers = callers.get(callee, set())

                # Module exports (M.*) are public interface - never treat as exclusive helpers
                is_module_export = callee.startswith('M.')

                if callee_fanin == 1 and callee_callers <= cluster and not is_module_export:
                    cluster.add(callee)
                    claimed.add(callee)
                    add_exclusive_subtree(callee, depth+1)  # Recursive

        add_exclusive_subtree(orch)

        if len(cluster) > 1:
            clusters.append(cluster)

    # Handle remaining unclaimed functions (leaves with no orchestrator, or shared helpers)
    # Exclude module interface functions (M.*) - those are intentional, not unclaimed
    unclaimed = {fn for fn in (structural_functions - claimed) if not fn.startswith('M.')}
    unclaimed_details = []

    if unclaimed:
        print(f"# {len(unclaimed)} unclaimed internal functions", file=sys.stderr)

        # Categorize and explain unclaimed functions
        for fn in sorted(unclaimed):
            fanin_val = fanin.get(fn, 0)
            fanout_val = fanout.get(fn, 0)
            caller_list = list(callers.get(fn, set()))

            # Determine why it's unclaimed
            if fanin_val == 0:
                reason = "dead code or orphaned"
            elif fanin_val == 1 and caller_list:
                reason = f"called only by {caller_list[0]} (non-orchestrator)"
            elif fanin_val >= 3:
                reason = f"shared helper (fanin={fanin_val})"
            else:
                reason = f"fanin={fanin_val}, fanout={fanout_val}"

            unclaimed_details.append((fn, reason))

        # Group unclaimed functions by shared callers (potential utility clusters)
        utility_clusters = defaultdict(set)
        for fn in unclaimed:
            caller_tuple = tuple(sorted(callers.get(fn, set())))
            if len(caller_tuple) >= 2:  # Called by multiple functions
                utility_clusters[caller_tuple].add(fn)

        for caller_set, fns in utility_clusters.items():
            if len(fns) >= 2:  # At least 2 shared helpers
                clusters.append(fns)
                claimed.update(fns)

    print(f"# Created {len(clusters)} call tree clusters", file=sys.stderr)

    results = []
    for idx, cluster in enumerate(sorted(clusters, key=len, reverse=True), 1):
        degree = Counter()
        for a in cluster:
            for b in adj[a]:
                if b in cluster:
                    degree[a] += 1

        # For call tree clusters, central function is the orchestrator (highest fanout)
        if degree:
            central = degree.most_common(1)[0][0]
            hub_strength = degree[central] / max(1, max(degree.values()))
        else:
            # No internal edges - pick function with highest fanout as central
            central = max(cluster, key=lambda f: len(calls.get(f, [])))
            hub_strength = 1.0  # It's the only orchestrator

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

            call_graph=call_graph,

        )

        # Build interface information (exported functions, entry points)
        exported_functions = [f for f in cluster if f.startswith('M.')]
        entry_points = []
        internal_only = []

        if call_graph:
            for f in exported_functions:
                if f in call_graph:
                    if call_graph[f].get('fanin', 0) == 0:
                        entry_points.append(f)
                    else:
                        internal_only.append(f)

        interface = {
            "exported_functions": sorted(exported_functions),
            "entry_points": sorted(entry_points),
            "internal_api": sorted(internal_only),
            "globals_used": [],  # TODO: detect global variable usage
            "globals_assessment": "None"  # TODO: assess globals
        }

        results.append({
            "id": idx,
            "type": cluster_type,
            "ownership": ownership,
            "interface": interface,
            "analysis": analysis,
            "functions": sorted(cluster),
            "files": {
                f: round(100 * l / max(1, total_loc))
                for f,l in by_file.items()
            }
        })

    # Return results along with diagnostic information
    diagnostics = {
        "utilities": sorted(utility_details, key=lambda x: x[1], reverse=True),
        "unclaimed": unclaimed_details
    }
    return results, diagnostics

# -------------------------
# Output
# -------------------------


def print_module_interface_summary(call_graph, analyzed_files):
    """Print summary of module public interface across all analyzed files."""
    if not call_graph:
        return

    # Group functions by file
    by_file = defaultdict(lambda: {"exported": [], "entry_points": [], "internal": []})

    for fn_name, fn_data in call_graph.items():
        if not fn_name.startswith('M.'):
            continue  # Only show exported functions

        file_path = fn_data.get('file', '')
        # Check if this file is in the analyzed set
        if not any(str(analyzed_file) in file_path for analyzed_file in analyzed_files):
            continue

        fanin = fn_data.get('fanin', 0)
        short_file = file_path.split('/')[-1]

        by_file[short_file]["exported"].append(fn_name)
        if fanin == 0:
            by_file[short_file]["entry_points"].append(fn_name)
        else:
            by_file[short_file]["internal"].append(fn_name)

    if not by_file:
        return

    print("=" * 70)
    print("MODULE INTERFACE SUMMARY")
    print("=" * 70)
    print()

    for file_name in sorted(by_file.keys()):
        data = by_file[file_name]
        if not data["exported"]:
            continue

        print(f"Module: {file_name}")
        print(f"  Module API ({len(data['exported'])} functions):")

        # Show exported functions, annotate those called internally
        for fn in sorted(data["exported"]):
            if fn in data["internal"]:
                print(f"    - {fn}  [called internally]")
            else:
                print(f"    - {fn}")

        print()

    print("=" * 70)
    print()


def print_text(results, diagnostics=None, call_graph=None, analyzed_files=None):
    # Print module interface summary first
    if analyzed_files:
        print_module_interface_summary(call_graph, analyzed_files)

    for r in results:
        print(f"CLUSTER {r['id']}")
        print(f"Type: {r['type']}")
        print()
        own, mod = r["ownership"]
        print(f"{own} of {mod}.")
        print()

        # Print Analysis FIRST (before Files/Functions)
        analysis = r.get("analysis") or {}
        sentences = analysis.get("sentences") or []
        if sentences:
            print("Analysis:")
            for s in sentences:
                print(s)
            print()

        # Print Interface (module public API)
        interface = r.get("interface") or {}
        exported = interface.get("exported_functions", [])
        internal_api = interface.get("internal_api", [])

        if exported:
            print("Interface:")
            for fn in exported:
                if fn in internal_api:
                    print(f"  {fn}  [called internally]")
                else:
                    print(f"  {fn}")
            print()

        print("Files:")
        for f, p in r["files"].items():
            print(f"{f}: {p}%")
        print()

        print("Functions:")
        for fn in r["functions"]:
            print(fn)
        print()

        # Check for dead code and duplicates
        if call_graph:
            dead_code = []
            duplicates = []
            for fn in r["functions"]:
                if fn in call_graph:
                    fn_data = call_graph[fn]
                    if fn_data.get('fanin', 0) == 0:
                        dead_code.append(fn)
                    dup_files = fn_data.get('duplicate_files', [])
                    if dup_files:
                        duplicates.append((fn, dup_files))

            if dead_code:
                print("⚠ WARNING: Potentially dead code (fanin=0, not called):")
                for fn in dead_code:
                    print(f"  - {fn}")
                print()

            if duplicates:
                print("⚠ WARNING: Duplicate definitions:")
                for fn, files in duplicates:
                    file_list = ", ".join([f.split("/")[-1] for f in files])
                    print(f"  - {fn}: {file_list}")
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

    # Print diagnostics at the end
    if diagnostics:
        print("=" * 70)
        print("DIAGNOSTICS")
        print("=" * 70)
        print()

        utilities = diagnostics.get("utilities", [])
        if utilities:
            print(f"Utilities excluded from clustering ({len(utilities)}):")
            for fn, fanin_val, files_calling in utilities:
                print(f"  {fn}: fanin={fanin_val}, files_calling={files_calling}")
            print()

        unclaimed = diagnostics.get("unclaimed", [])
        if unclaimed:
            print(f"Unclaimed internal functions ({len(unclaimed)}):")
            for fn, reason in unclaimed:
                print(f"  {fn}: {reason}")
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
    ap.add_argument("--call-graph", help="Path to global call graph JSON (optional, will auto-generate if missing)")
    ap.add_argument("--update-call-graph", "-ug", action="store_true", help="Force regenerate call graph cache")
    args = ap.parse_args()

    generic_roots = set(DEFAULT_GENERIC_CONTEXT_ROOTS)
    if args.generic_roots:
        generic_roots |= {r.strip() for r in args.generic_roots.split(",") if r.strip()}

    # Auto-generate call graph if needed
    call_graph_path = args.call_graph or "docs/lua-call-graph.json"
    call_graph_needs_update = args.update_call_graph or not Path(call_graph_path).exists()

    if call_graph_needs_update:
        print(f"# Generating call graph cache at {call_graph_path}...", file=sys.stderr)
        import subprocess
        # Use venv Python to ensure luaparser is available
        script_dir = Path(__file__).parent
        venv_python = script_dir.parent / ".venv" / "bin" / "python3"
        python_executable = str(venv_python) if venv_python.exists() else sys.executable

        result = subprocess.run(
            [python_executable, "scripts/build_call_graph_ast.py", "src/lua", "--output", call_graph_path],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            print(f"# Warning: Call graph generation failed: {result.stderr}", file=sys.stderr)
            call_graph = None
        else:
            print(f"# Call graph cache generated", file=sys.stderr)

    # Load call graph
    call_graph = None
    if Path(call_graph_path).exists():
        call_graph = load_call_graph(call_graph_path)
        print(f"# Loaded call graph with {len(call_graph)} functions", file=sys.stderr)
    else:
        print(f"# Warning: No call graph available", file=sys.stderr)

    results, diagnostics = analyze(
        [Path(p) for p in args.paths],
        generic_roots,
        explain_suppressed=args.explain_suppressed,
        call_graph=call_graph
    )

    if args.json:
        print_json(results, args.paths)
    else:
        print_text(results, diagnostics, call_graph, analyzed_files=[Path(p) for p in args.paths])

if __name__ == "__main__":
    main()
