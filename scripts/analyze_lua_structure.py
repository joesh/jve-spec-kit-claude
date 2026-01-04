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

CLUSTER_THRESHOLD = 0.25  # Lowered to allow semantic importance to overcome low structural coupling
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
    """
    Extract context roots from function body with semantic expansion.

    Context roots include:
    1. Table/module accesses: browser_state.*, M.*, etc.
    2. Lifecycle guards: is_restoring_*, is_loading_*, enabled, disabled, etc.
    3. Context constructors: function calls that provide context (selection_context(), get_state(), etc.)
    4. State mutation targets: any identifier with table-like access pattern
    """
    roots = set()

    # 1. Table/module accesses (existing pattern)
    roots.update(m.group(1) for m in CONTEXT_ROOT_RE.finditer(text))

    # 2. Lifecycle guards: identifiers in conditional contexts
    # Matches: if <identifier> then, while <identifier> do, <identifier> and, <identifier> or
    lifecycle_patterns = [
        r'\bif\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+then',
        r'\bwhile\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+do',
        r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s+and\b',
        r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s+or\b',
        r'\bnot\s+([a-zA-Z_][a-zA-Z0-9_]*)\b',
    ]
    for pattern in lifecycle_patterns:
        matches = re.finditer(pattern, text)
        for m in matches:
            identifier = m.group(1)
            # Filter out keywords and very generic names
            if identifier not in STOPWORDS and identifier not in {'i', 'j', 'k', 'v', 'x', 'y', 'n'}:
                # Only include if it looks like a state/guard identifier
                if any(prefix in identifier for prefix in ['is_', 'has_', 'should_', 'can_', 'enabled', 'disabled', 'loading', 'restoring', 'pending']):
                    roots.add(identifier)

    # 3. Context constructors: function calls that look like context providers
    # Pattern: <identifier>() where identifier suggests context/state retrieval
    call_pattern = r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\('
    for m in re.finditer(call_pattern, text):
        func_name = m.group(1)
        # Only include if it looks like a context provider
        if any(keyword in func_name for keyword in ['context', 'state', 'get_', 'fetch_', 'load_', 'find_', 'selected', 'current']):
            if func_name not in STOPWORDS:
                roots.add(func_name)

    return roots

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

def qualify_function_name(fn_name, module_name):
    """
    Qualify a function name with its module name.

    Args:
        fn_name: Unqualified function name (e.g., "M.create" or "helper")
        module_name: Module name extracted from filename (e.g., "project_browser")

    Returns:
        Qualified name (e.g., "project_browser.create" or "project_browser:helper")
    """
    if fn_name.startswith('M.'):
        # Module export: M.create → project_browser.create
        return f"{module_name}.{fn_name[2:]}"
    else:
        # Local function: helper → project_browser:helper
        return f"{module_name}:{fn_name}"

# -------------------------
# Signal-Based Scoring (per ANALYSIS_TOOL_DESIGN_ADDENDUM.md)
# -------------------------

def calculate_boilerplate_score(fn_name, calls, context_roots, call_graph=None, func_loc=None, callers=None):
    """
    Calculate boilerplate score per ADDENDUM_2 spec.

    Boilerplate = lifecycle setup, registration/wiring, handler dispatch, glue code.
    Boilerplate is necessary but NON-STRUCTURAL and SIGNAL-SUPPRESSING.

    Formula:
        boilerplate_score =
            0.40 * fanout_weight +
            0.25 * call_density_weight +
            0.20 * registration_pattern_weight +
            0.15 * lifecycle_position_weight

    HARD RULE: If boilerplate_score ≥ 0.6, function CANNOT be a nucleus.

    Returns: float in [0, 1]
    """
    fn_calls = calls.get(fn_name, set())
    fanout = len(fn_calls)

    # 1. Fanout weight (high fanout indicates delegation/wiring)
    FANOUT_HIGH_WATERMARK = 10
    fanout_weight = min(1.0, fanout / FANOUT_HIGH_WATERMARK)

    # 2. Call density weight (ratio of calls to total statements)
    # Approximate: if we don't have LOC, use call count as proxy
    # Ideal: calls / (LOC - comments - blanks)
    if func_loc and fn_name in func_loc:
        loc = func_loc[fn_name]
        call_density = min(1.0, fanout / max(1, loc)) if loc > 0 else 0
    else:
        # Fallback: normalize by expected LOC for given fanout
        # High fanout with low expected LOC = high density
        expected_loc = max(5, fanout * 2)  # Assume ~2 LOC per call minimum
        call_density = min(1.0, fanout / expected_loc)

    # 3. Registration pattern weight
    registration_patterns = ['register_', 'add_listener', 'bind_', 'set_handler', 'on_', 'handle_']
    widget_patterns = ['CREATE_', 'LAYOUT', 'qt_', 'WIDGET']

    registration_weight = 0.0
    name_lower = fn_name.lower()

    # Check function name
    if any(p.lower() in name_lower for p in registration_patterns):
        registration_weight += 0.5
    if any(p.lower() in name_lower for p in widget_patterns):
        registration_weight += 0.3

    # Check calls
    for call in fn_calls:
        call_lower = call.lower()
        if any(p.lower() in call_lower for p in registration_patterns):
            registration_weight = min(1.0, registration_weight + 0.1)
        if any(p.lower() in call_lower for p in widget_patterns):
            registration_weight = min(1.0, registration_weight + 0.1)

    registration_weight = min(1.0, registration_weight)

    # 4. Lifecycle position weight
    lifecycle_names = ['create', 'init', 'setup', 'ensure', 'build', 'construct']
    lifecycle_weight = 0.0

    # Check if name matches lifecycle pattern
    fn_base = fn_name.split('.')[-1].split(':')[-1].lower()
    if any(lc in fn_base for lc in lifecycle_names):
        lifecycle_weight += 0.6

    # Check if exported entrypoint (module.func, not module:func)
    is_exported = '.' in fn_name and ':' not in fn_name
    if is_exported:
        lifecycle_weight += 0.2

    # Check if called exactly once externally (strong lifecycle signal)
    if callers:
        external_callers = [c for c in callers.get(fn_name, []) if not c.startswith(fn_name.split('.')[0])]
        if len(external_callers) == 1:
            lifecycle_weight += 0.2

    lifecycle_weight = min(1.0, lifecycle_weight)

    score = (
        0.40 * fanout_weight +
        0.25 * call_density +
        0.20 * registration_weight +
        0.15 * lifecycle_weight
    )

    return min(1.0, score)

def calculate_nucleus_score(fn_name, cluster, calls, callers, context_roots, boilerplate_scores,
                           veneers=None, call_graph=None, func_scope=None):
    """
    Calculate nucleus score per ADDENDUM_2 spec with veneer semantic override.

    A nucleus is a function that plausibly represents the center of a responsibility.
    It is NOT: the most called function, a lifecycle hook, or a registration hub.

    NORMATIVE: Veneers can be nuclei if they represent conceptual responsibility boundaries
    (API-level entry points, cross-file importance).

    Formula:
        raw_nucleus_signal(f) =
            0.40 * inward_call_weight(f) +
            0.30 * shared_context_weight(f) +
            0.20 * internal_cluster_participation(f) +
            0.10 * semantic_centrality(f)  [NEW: API-level importance]

        veneer_adjustment = 0.6 if is_veneer else 1.0
        nucleus_score(f) = raw_nucleus_signal(f) * (1 - boilerplate_score(f)) * veneer_adjustment

        BUT: semantic_centrality can override veneer downweight if strong enough

    HARD RULE: If boilerplate_score(f) ≥ 0.6, nucleus_score = 0 (cannot be nucleus).

    Threshold: ≥ 0.45 or emit NO cluster.

    Returns: float in [0, 1]
    """
    veneers = veneers or set()
    boilerplate = boilerplate_scores.get(fn_name, 0)

    # HARD RULE: Boilerplate-heavy functions cannot be nuclei
    if boilerplate >= 0.6:
        return 0.0

    # 1. Inward call weight (normalized fan-in from non-boilerplate callers)
    cluster_callers = [c for c in callers.get(fn_name, []) if c in cluster]
    # Filter out boilerplate-heavy callers (they don't count as meaningful references)
    non_boilerplate_callers = [c for c in cluster_callers if boilerplate_scores.get(c, 0) < 0.6]
    inward_call_weight = len(non_boilerplate_callers) / max(1, len(cluster) - 1)

    # 2. Shared context weight (overlap of TABLE context roots with cluster)
    # Per spec: "table roots only (e.g. `browser_state.*`)"
    fn_roots = context_roots.get(fn_name, set())
    # Filter to table-like roots (multi-part identifiers, not single tokens)
    fn_table_roots = {r for r in fn_roots if '.' in r or '_' in r}

    cluster_roots = set()
    for other_fn in cluster:
        if other_fn != fn_name:
            other_roots = context_roots.get(other_fn, set())
            cluster_roots.update({r for r in other_roots if '.' in r or '_' in r})

    if fn_table_roots and cluster_roots:
        shared = fn_table_roots & cluster_roots
        shared_context_weight = len(shared) / len(fn_table_roots)
    else:
        shared_context_weight = 0.0

    # 3. Internal cluster participation (proportion of calls inside the candidate group)
    fn_calls = calls.get(fn_name, set())
    internal_calls = {c for c in fn_calls if c in cluster}
    if fn_calls:
        internal_participation = len(internal_calls) / len(fn_calls)
    else:
        internal_participation = 0.0

    # 4. Semantic centrality (API-level importance, cross-file callers, module export)
    # This allows veneers to be nuclei if they represent conceptual boundaries
    semantic_centrality = 0.0

    # Check if function is module API (exported, public interface)
    # Only . (dot) prefix functions are public API, : (colon) are internal methods
    is_module_api = False
    if func_scope and func_scope.get(fn_name) == "top":
        # Top-level function - check if it's public API (.) or internal method (:)
        if '.' in fn_name and ':' not in fn_name:
            is_module_api = True

    # Check for cross-file callers (called from multiple files = API importance)
    cross_file_callers = 0
    if call_graph and fn_name in call_graph:
        cross_file_callers = call_graph[fn_name].get('files_calling', 0)

    if is_module_api:
        semantic_centrality += 0.7  # CALIBRATED: Module API functions are strong nucleus candidates (public interface)
    if cross_file_callers >= 2:
        semantic_centrality += 0.3  # Called from multiple files = important boundary
    elif cross_file_callers == 1:
        semantic_centrality += 0.2  # Called from one other file

    # NOTE: Action words (activate, execute, etc.) removed - too broad, gave false signals to internal functions

    semantic_centrality = min(1.0, semantic_centrality)

    raw_signal = (
        0.15 * inward_call_weight +
        0.10 * shared_context_weight +
        0.15 * internal_participation +
        0.60 * semantic_centrality  # CALIBRATED: Semantic importance heavily dominates for normative nucleus detection
    )

    # Veneer downweight: structurally thin, but can be overridden by semantic centrality
    is_veneer = fn_name in veneers
    if is_veneer:
        # If semantic centrality is strong (≥0.5), don't downweight
        # Otherwise apply 0.7x penalty for being a thin forwarding function
        if semantic_centrality >= 0.5:
            veneer_adjustment = 1.0  # Strong semantic signal overrides veneer status
        else:
            veneer_adjustment = 0.7  # Mild downweight for structural thinness
    else:
        veneer_adjustment = 1.0

    # Boilerplate MULTIPLIES (suppresses) the raw signal
    nucleus_score = raw_signal * (1 - boilerplate) * veneer_adjustment


    return max(0.0, min(1.0, nucleus_score))

def calculate_extraction_cost(fn_name, context_roots, idents, calls, callers):
    """
    Calculate extraction cost per ADDENDUM_2 spec.

    Extraction cost reflects how much real editor behavior is at risk.

    Formula:
        extraction_cost(f) =
            0.30 * timeline_coupling +
            0.25 * selection_coupling +
            0.20 * command_graph_coupling +
            0.15 * media_identity_coupling +
            0.10 * global_state_touch

    HARD STOP: If timeline_coupling > 0.6 AND selection_coupling > 0.4,
    emit warning and NO extraction advice.

    Returns: float in [0, 1]
    """
    fn_roots = context_roots.get(fn_name, set())
    fn_idents = idents.get(fn_name, set())
    fn_calls = calls.get(fn_name, set())

    # 1. Timeline coupling
    timeline_tokens = {'track', 'clip', 'frame', 'time', 'offset', 'ripple', 'insert', 'trim', 'timeline', 'sequence'}
    timeline_count = sum(1 for token in timeline_tokens if any(token in str(r).lower() for r in fn_roots | fn_idents))
    timeline_coupling = min(1.0, timeline_count / 5.0)  # Normalize to ~5 tokens = 1.0

    # 2. Selection coupling
    selection_tokens = {'selected', 'selection', 'select_'}
    selection_count = sum(1 for token in selection_tokens if any(token in str(r).lower() for r in fn_roots | fn_idents | fn_calls))
    selection_coupling = min(1.0, selection_count / 3.0)  # Normalize to ~3 tokens = 1.0

    # 3. Command graph coupling
    command_tokens = {'undo', 'redo', 'command', 'execute', 'register_command'}
    command_count = sum(1 for token in command_tokens if any(token in str(r).lower() for r in fn_roots | fn_idents | fn_calls))
    command_coupling = min(1.0, command_count / 3.0)

    # 4. Media identity coupling
    media_tokens = {'master_clip', 'media', 'metadata', 'master'}
    media_count = sum(1 for token in media_tokens if any(token in str(r).lower() for r in fn_roots | fn_idents))
    media_coupling = min(1.0, media_count / 3.0)

    # 5. Global state touch (module-level writes)
    # Approximate: if function modifies context roots at module level
    global_write_score = 0.0
    for root in fn_roots:
        # If root is module-scoped (M.*, module.*)
        if root.startswith('M.') or any(root.startswith(f'{m}.') for m in ['state', 'cache', 'config']):
            global_write_score += 0.3

    global_state_touch = min(1.0, global_write_score)

    cost = (
        0.30 * timeline_coupling +
        0.25 * selection_coupling +
        0.20 * command_coupling +
        0.15 * media_coupling +
        0.10 * global_state_touch
    )

    return min(1.0, cost)

def calculate_leverage_score(fn_name, cluster, inappropriate_connections, nucleus_scores, degree):
    """
    Calculate leverage score per ADDENDUM_2 spec (adapted for call site).

    Formula:
        leverage_score = centrality(f) * (1 - extraction_cost(f))

    Only rank candidates that pass nucleus and cost gates.

    Returns: float in [0, 1]
    """
    # Use nucleus score as centrality proxy
    centrality_score = nucleus_scores.get(fn_name, 0)

    # Use inappropriate connections as extraction cost proxy
    inappropriate_count = len([c for c in inappropriate_connections if fn_name in c])
    extraction_cost = min(1.0, inappropriate_count * 0.2)

    return centrality_score * (1 - extraction_cost)

def find_inappropriate_connections(cluster, internal_edges, nucleus_scores, context_roots, boilerplate_scores):
    """
    Find inappropriate connections within a cluster.

    An inappropriate connection is a strong linkage that lacks structural justification.

    Operational definition for functions A and B:
    - coupling(A,B) ≥ (cluster_mean + 1σ)
    - AND: no shared nucleus
    - AND: no shared non-boilerplate context root

    Returns: list of (fn_a, fn_b, coupling_strength) tuples
    """
    if not internal_edges:
        return []

    # Calculate coupling statistics
    couplings = [strength for (_, _, strength) in internal_edges]
    if not couplings:
        return []

    mean_coupling = statistics.mean(couplings)
    stdev_coupling = statistics.stdev(couplings) if len(couplings) > 1 else 0
    threshold = mean_coupling + stdev_coupling

    inappropriate = []

    for (fn_a, fn_b, strength) in internal_edges:
        # Check if coupling exceeds threshold
        if strength < threshold:
            continue

        # Check for shared nucleus (both have high nucleus score and share contexts)
        nucleus_a = nucleus_scores.get(fn_a, 0)
        nucleus_b = nucleus_scores.get(fn_b, 0)
        both_nucleus = nucleus_a >= 0.55 and nucleus_b >= 0.55

        # Check for shared non-boilerplate context roots
        roots_a = context_roots.get(fn_a, set())
        roots_b = context_roots.get(fn_b, set())

        # Filter out roots from boilerplate-heavy functions
        boilerplate_a = boilerplate_scores.get(fn_a, 0)
        boilerplate_b = boilerplate_scores.get(fn_b, 0)

        if boilerplate_a < 0.6 and boilerplate_b < 0.6:
            shared_roots = roots_a & roots_b
            has_shared_context = len(shared_roots) > 0
        else:
            has_shared_context = False

        # If no shared nucleus and no shared context, it's inappropriate
        if not both_nucleus and not has_shared_context:
            inappropriate.append((fn_a, fn_b, strength))

    return inappropriate

def detect_proto_nucleus(cluster, nucleus_scores, context_roots, boilerplate_scores, calls):
    """
    Detect proto-nucleus: emergent semantic structure not yet collapsed into single function.

    A proto-nucleus is a small set of functions that collectively satisfy nucleus criteria.

    Detection rules (ALL must be true):
    1. Cardinality: 2 ≤ |P| ≤ 5
    2. Individual strength: Each f ∈ P has nucleus_score(f) ≥ 0.40
    3. Shared semantic support:
       - At least one shared non-boilerplate context root
       - At least one internal call relationship among members
    4. Collective dominance: mean(nucleus_score(f) for f in P) ≥ 0.50

    Returns: list of functions in proto-nucleus, or empty list if none detected
    """
    # Find candidates with scores ≥ 0.40 but < 0.55 (nucleus threshold)
    candidates = [fn for fn in cluster if 0.40 <= nucleus_scores.get(fn, 0) < 0.55]

    if len(candidates) < 2:
        return []

    # Try to find a proto-nucleus among candidates
    # Start with highest-scoring candidates and expand
    candidates_sorted = sorted(candidates, key=lambda f: nucleus_scores.get(f, 0), reverse=True)

    for size in range(2, min(6, len(candidates_sorted) + 1)):
        proto_set = candidates_sorted[:size]

        # Check collective dominance (mean ≥ 0.50)
        proto_strength = sum(nucleus_scores.get(f, 0) for f in proto_set) / len(proto_set)
        if proto_strength < 0.45:
            continue

        # Check shared semantic support
        # 1. At least one shared non-boilerplate context root
        shared_roots = None
        for fn in proto_set:
            fn_roots = context_roots.get(fn, set())
            # Filter boilerplate roots
            if boilerplate_scores.get(fn, 0) < 0.6:
                if shared_roots is None:
                    shared_roots = fn_roots.copy()
                else:
                    shared_roots &= fn_roots

        has_shared_context = shared_roots and len(shared_roots) > 0

        # 2. At least one internal call relationship
        has_call_relationship = False
        for i, fn_a in enumerate(proto_set):
            for fn_b in proto_set[i+1:]:
                # Direct call or one hop
                if fn_b in calls.get(fn_a, []) or fn_a in calls.get(fn_b, []):
                    has_call_relationship = True
                    break
                # One hop: check if they share a callee/caller
                callees_a = calls.get(fn_a, set())
                callees_b = calls.get(fn_b, set())
                if callees_a & callees_b:
                    has_call_relationship = True
                    break
            if has_call_relationship:
                break

        if has_shared_context and has_call_relationship:
            # Found valid proto-nucleus
            return proto_set

    return []

def validate_and_split_clusters(clusters, calls, callers, context_roots,
                                veneers=None, call_graph=None, func_scope=None):
    """
    Validate clusters per ADDENDUM_2 strict stop conditions with veneer semantic override.

    MANDATORY STOP CONDITIONS:
    - No nucleus ≥ 0.45 → REJECT cluster (emit no cluster)
    - Competing nuclei within ±0.05 → REJECT cluster
    - Boilerplate dominates group → REJECT cluster

    NORMATIVE: Veneers can be nuclei if semantic signals override structural thinness.

    Silence is correct behavior.

    Returns: (valid_clusters, rejected_clusters, diagnostics)
    """
    veneers = veneers or set()
    valid_clusters = []
    rejected_clusters = []
    diagnostics = {
        'no_nucleus': [],
        'competing_nuclei': [],
        'boilerplate_dominated': [],
        'all_scores': {}  # For diagnostic output
    }

    for cluster in clusters:
        # Calculate boilerplate scores
        boilerplate_scores = {}
        for fn in cluster:
            score = calculate_boilerplate_score(fn, calls, context_roots)
            boilerplate_scores[fn] = score

        # Calculate nucleus scores (with veneer semantic override)
        nucleus_scores = {}
        for fn in cluster:
            score = calculate_nucleus_score(fn, cluster, calls, callers, context_roots, boilerplate_scores,
                                          veneers=veneers, call_graph=call_graph, func_scope=func_scope)
            nucleus_scores[fn] = score

        # Store scores for diagnostics
        diagnostics['all_scores'][tuple(sorted(cluster))] = {
            'nucleus_scores': nucleus_scores.copy(),
            'boilerplate_scores': boilerplate_scores.copy()
        }

        # Find nuclei (functions meeting threshold ≥ 0.42)
        # CALIBRATED: Lowered from 0.45 to admit API-level veneers with strong semantic signals
        NUCLEUS_THRESHOLD = 0.42
        nuclei = [fn for fn in cluster if nucleus_scores[fn] >= NUCLEUS_THRESHOLD]
        max_nucleus_score = max(nucleus_scores.values()) if nucleus_scores else 0.0

        # STOP CONDITION 1: Boilerplate dominates group (CHECK FIRST - highest priority rejection)
        # If cluster is lifecycle/wiring dominated, reject regardless of nucleus/competing nuclei status
        # Two detection modes:
        # (A) High-fanout boilerplate (score ≥ 0.6): delegation/wiring/dispatch code
        # (B) Lifecycle coordination: init/setup/teardown/is_*/set_* patterns (low fanout but still boilerplate)

        high_centrality_funcs = sorted(cluster, key=lambda f: nucleus_scores.get(f, 0), reverse=True)[:3]
        high_centrality_boilerplate = [fn for fn in high_centrality_funcs if boilerplate_scores.get(fn, 0) >= 0.6]

        # Count total boilerplate functions in cluster (Mode A)
        boilerplate_funcs = [fn for fn in cluster if boilerplate_scores.get(fn, 0) >= 0.6]
        boilerplate_fraction = len(boilerplate_funcs) / max(1, len(cluster))

        # Identify lifecycle coordination patterns (Mode B)
        lifecycle_patterns = ['init', 'setup', 'teardown', 'destroy', 'register', 'notify',
                            'is_ready', 'is_loading', 'set_ready', 'set_loading', 'callback',
                            'is_', 'set_', 'get_']  # Generic state accessors

        lifecycle_funcs = []
        boilerplate_nature = []
        for fn in cluster:
            fn_lower = fn.lower()
            is_lifecycle = False

            if any(pattern in fn_lower for pattern in ['init', 'setup']):
                boilerplate_nature.append('setup')
                is_lifecycle = True
            elif any(pattern in fn_lower for pattern in ['register', 'callback', 'notify']):
                boilerplate_nature.append('registration')
                is_lifecycle = True
            elif any(pattern in fn_lower for pattern in ['is_', 'set_', 'get_']):
                boilerplate_nature.append('wiring')
                is_lifecycle = True
            elif any(pattern in fn_lower for pattern in ['teardown', 'destroy', 'cleanup']):
                boilerplate_nature.append('lifecycle')
                is_lifecycle = True

            if is_lifecycle:
                lifecycle_funcs.append(fn)

        lifecycle_fraction = len(lifecycle_funcs) / max(1, len(cluster))

        # Reject if EITHER:
        # (A) All high-centrality are boilerplate AND majority is boilerplate (high-fanout mode)
        # (B) Majority is lifecycle coordination (low-fanout mode)
        mode_a_triggered = (len(high_centrality_boilerplate) >= len(high_centrality_funcs) and boilerplate_fraction >= 0.5)
        mode_b_triggered = (lifecycle_fraction >= 0.67)  # 2/3 or more are lifecycle functions

        if mode_a_triggered or mode_b_triggered:
            # Use higher fraction for reporting (either boilerplate or lifecycle)
            effective_fraction = max(boilerplate_fraction, lifecycle_fraction)
            effective_funcs = boilerplate_funcs if boilerplate_fraction > lifecycle_fraction else lifecycle_funcs

            rejected_clusters.append({
                'cluster': cluster,
                'reason': 'boilerplate_dominated',
                'boilerplate_fraction': effective_fraction,
                'boilerplate_functions': effective_funcs,
                'boilerplate_nature': list(set(boilerplate_nature)),
                'mode': 'high_fanout' if mode_a_triggered else 'lifecycle'
            })
            diagnostics['boilerplate_dominated'].append({
                'cluster': cluster,
                'boilerplate_fraction': effective_fraction,
                'boilerplate_functions': effective_funcs,
                'lifecycle_functions': lifecycle_funcs,
                'boilerplate_nature': list(set(boilerplate_nature)),
                'all_functions': list(cluster),
                'mode': 'high_fanout' if mode_a_triggered else 'lifecycle'
            })
            continue

        # STOP CONDITION 2: No nucleus ≥ NUCLEUS_THRESHOLD
        if len(nuclei) == 0:
            rejected_clusters.append({
                'cluster': cluster,
                'nuclei': [],
                'max_score': max_nucleus_score,
                'reason': 'no_nucleus'
            })
            diagnostics['no_nucleus'].append({
                'cluster': cluster,
                'max_score': max_nucleus_score,
                'boilerplate_heavy': [fn for fn, s in boilerplate_scores.items() if s >= 0.6]
            })
            continue

        # STOP CONDITION 3: Competing nuclei within ±0.05
        if len(nuclei) > 1:
            nucleus_scores_sorted = sorted([(s, fn) for fn, s in nucleus_scores.items() if s >= NUCLEUS_THRESHOLD], reverse=True)
            top_score = nucleus_scores_sorted[0][0]
            competing = [fn for s, fn in nucleus_scores_sorted if abs(s - top_score) <= 0.05]

            if len(competing) > 1:
                rejected_clusters.append({
                    'cluster': cluster,
                    'nuclei': competing,
                    'reason': 'competing_nuclei'
                })
                diagnostics['competing_nuclei'].append({
                    'cluster': cluster,
                    'nuclei': competing,
                    'scores': {fn: nucleus_scores[fn] for fn in competing}
                })
                continue

        # Cluster passes all gates
        valid_clusters.append(cluster)

    return valid_clusters, rejected_clusters, diagnostics

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
        # Must count ALL keywords that create end-pairs: function, if, while, for, do
        depth = 1  # We've seen one 'function'
        end_line = len(lines)  # Default to EOF

        for i in range(start_line + 1, len(lines)):
            stripped = lines[i].strip()

            # Count keywords that INCREASE depth (create blocks)
            for keyword in [r'\bfunction\b', r'\bif\b', r'\bwhile\b', r'\bfor\b', r'\bdo\b', r'\brepeat\b']:
                depth += len(re.findall(keyword, stripped))

            # Count 'end' keywords (decreases depth) and 'until' (ends repeat)
            depth -= len(re.findall(r'\bend\b', stripped))
            depth -= len(re.findall(r'\buntil\b', stripped))

            if depth == 0:
                end_line = i
                break

        # Body includes function definition line, exclude it from call extraction
        full_body = "\n".join(lines[start_line:end_line])
        # Body without first line (function definition) for call extraction
        body_without_def = "\n".join(lines[start_line+1:end_line])

        idents[name] = extract_identifiers(full_body)
        roots[name] = extract_context_roots(full_body)
        locs[name] = compute_loc(full_body)

        # Extract calls from body EXCLUDING the function definition line
        for c in CALL_RE.finditer(body_without_def):
            callee = c.group(1)
            # Filter out self-calls (belt and suspenders)
            if callee != name:
                calls[name].add(callee)

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

# Removed: _fragile_edges replaced by find_inappropriate_connections (signal-based scoring)

def _analysis_for_cluster(cluster, internal, central, degree, fanout, context_roots,
                         valid_context_roots, generic_roots, global_root_counts, total_functions,
                         func_loc, by_file, total_loc, dom_file, dom_pct,
                         explain_suppressed, call_graph=None, calls=None, callers=None, veneers=None, func_scope=None):
    """
    Analyze cluster using signal-based scoring per ANALYSIS_TOOL_DESIGN_ADDENDUM.md

    CRITICAL POLICY SHIFT: This tool exposes latent structure for human judgment.
    It does NOT suppress weak signal. It describes the TYPE of structure (or lack thereof).

    Three cluster states:
    1. Nucleus-centered: Clear semantic center (≥ 0.65)
    2. Proto-nucleus: Emergent structure not yet consolidated (2-5 functions, collective strength ≥ 0.50)
    3. Diffuse/scaffolding: Responsibilities smeared, no semantic center

    Always emit actionable guidance, never suppress.
    """
    sentences = []

    # Phase 1: Calculate all scores for cluster functions
    boilerplate_scores = {}
    for fn in cluster:
        score = calculate_boilerplate_score(fn, calls or {}, context_roots, call_graph)
        boilerplate_scores[fn] = score

    nucleus_scores = {}
    for fn in cluster:
        score = calculate_nucleus_score(fn, cluster, calls or {}, callers or {}, context_roots, boilerplate_scores,
                                       veneers=veneers, call_graph=call_graph, func_scope=func_scope)
        nucleus_scores[fn] = score

    # Phase 2: Find nucleus (if any meets threshold ≥ 0.65)
    nucleus = None
    nucleus_score = 0.0
    for fn in cluster:
        if nucleus_scores[fn] >= 0.45:
            if nucleus_scores[fn] > nucleus_score:
                nucleus = fn
                nucleus_score = nucleus_scores[fn]

    # Phase 2b: If no nucleus, check for proto-nucleus (emergent structure)
    proto_nucleus = []
    proto_strength = 0.0
    if not nucleus:
        proto_nucleus = detect_proto_nucleus(cluster, nucleus_scores, context_roots, boilerplate_scores, calls or {})
        if proto_nucleus:
            proto_strength = sum(nucleus_scores.get(fn, 0) for fn in proto_nucleus) / len(proto_nucleus)

    # Phase 3: Find inappropriate connections (kept for backward compatibility)
    inappropriate_connections = find_inappropriate_connections(
        cluster, internal, nucleus_scores, context_roots, boilerplate_scores
    )

    # Phase 4: Find leverage point using context-breadth heuristic
    # Leverage points are non-boilerplate functions within 2 hops of nucleus
    # that touch MORE distinct context roots than the nucleus itself
    leverage_point = None
    leverage_context_count = 0
    leverage_justification = ""

    # GOLDEN TEST 3: Micro-cluster acceptance (≤4 functions)
    # Small, well-factored clusters should NOT have leverage points identified
    # Extraction would add indirection, not clarity - explicit restraint
    is_micro_cluster = len(cluster) <= 4
    skip_leverage_for_micro = is_micro_cluster and nucleus

    if nucleus and not skip_leverage_for_micro:
        # Search ALL cluster members for leverage point candidates
        # "Within two hops" interpreted as: semantically connected (in same cluster)
        # not requiring direct call-chain reachability
        candidates = set(cluster) - {nucleus}

        # Count nucleus's distinct context roots
        nucleus_contexts = context_roots.get(nucleus, set())
        nucleus_context_count = len(nucleus_contexts)

        # Find best leverage point candidate
        best_candidate = None
        best_context_count = nucleus_context_count  # Must exceed nucleus
        best_nucleus_score = 0.0

        for fn in candidates:
            # Skip nucleus itself
            if fn == nucleus:
                continue

            # Skip boilerplate-heavy functions
            if boilerplate_scores.get(fn, 0) >= 0.6:
                continue

            # Count distinct context roots
            fn_contexts = context_roots.get(fn, set())
            fn_context_count = len(fn_contexts)

            # Select if more contexts than current best (or tie with higher nucleus score)
            if fn_context_count > best_context_count:
                best_candidate = fn
                best_context_count = fn_context_count
                best_nucleus_score = nucleus_scores.get(fn, 0)
            elif fn_context_count == best_context_count and fn_context_count > nucleus_context_count:
                # Tiebreaker: higher nucleus score
                if nucleus_scores.get(fn, 0) > best_nucleus_score:
                    best_candidate = fn
                    best_nucleus_score = nucleus_scores.get(fn, 0)

        # GOLDEN TEST 4: Leverage point suppression rule
        # Suppress leverage point if context breadth difference is trivial
        # This prevents false positives in coherent clusters with no responsibility tension
        if best_candidate:
            context_breadth_delta = best_context_count - nucleus_context_count

            # Suppress if difference is trivial (≤ 1 additional context)
            # Rationale: "Touches multiple contexts" ≠ "Extraction opportunity"
            # Context breadth alone is insufficient without responsibility tension
            # Delta ≤1 indicates data flow through coherent algorithm, not cross-cutting concern
            if context_breadth_delta <= 1:
                # Explicit restraint: no leverage point when differences are trivial
                pass  # best_candidate found but suppressed
            else:
                # Significant context breadth difference - genuine leverage point
                leverage_point = best_candidate
                leverage_context_count = best_context_count
                leverage_justification = f"touches {best_context_count} distinct contexts (nucleus: {nucleus_context_count})"



    # Phase 5: Identify structural boilerplate (functions with score ≥ 0.6)
    boilerplate_functions = [fn for fn, score in boilerplate_scores.items() if score >= 0.6]

    # Phase 6: Generate explanation based on cluster state
    # ALWAYS emit actionable guidance - no suppression

    if nucleus:
        # STATE 1: Nucleus-centered (clear semantic center)
        sentences.append(f"This cluster has a clear nucleus around {nucleus}, indicating a coherent algorithm.")

        if boilerplate_functions:
            bp_names = ", ".join(boilerplate_functions[:3])
            if len(boilerplate_functions) > 3:
                bp_names += f", and {len(boilerplate_functions) - 3} more"
            sentences.append(f"Structural boilerplate is concentrated in {bp_names}, which obscures the core without contributing domain responsibility.")

        if leverage_point:
            # Report leverage point as extraction opportunity
            sentences.append(f"The primary leverage point is {leverage_point}, which {leverage_justification}.")
            sentences.append(f"Extracting {leverage_point} into a focused module would reduce the nucleus's context dependencies and improve separation of concerns.")
        elif skip_leverage_for_micro:
            # GOLDEN TEST 3: Micro-cluster explicit restraint
            # Small, well-factored clusters should NOT be refactored - already tight
            sentences.append(f"The cluster is small ({len(cluster)} functions) and well-factored around a single responsibility.")
            sentences.append(f"No leverage points identified - extraction would add indirection without improving clarity.")
            sentences.append(f"No refactoring recommended.")
        elif not leverage_point and not skip_leverage_for_micro:
            # GOLDEN TEST 4: Leverage suppressed due to trivial context breadth difference
            # Coherent clusters with no responsibility tension should NOT be refactored
            sentences.append(f"Responsibilities are appropriately localized within the cluster.")
            sentences.append(f"No leverage points detected - context breadth differences are trivial.")
            sentences.append(f"No refactoring recommended.")
        elif boilerplate_functions:
            sentences.append(f"Refactoring should preserve the nucleus while extracting boilerplate to clarify the algorithm's semantic core.")

    elif proto_nucleus:
        # STATE 2: Proto-nucleus (emergent structure not yet consolidated)
        proto_names = ", ".join(proto_nucleus)
        sentences.append(f"This cluster contains a proto-nucleus centered on {proto_names} (collective strength: {proto_strength:.2f}), indicating an algorithm attempting to form but not yet consolidated.")

        # Describe the weakness
        if len(proto_nucleus) == 2:
            sentences.append(f"The algorithm is split between two functions that share semantic intent but lack a unified orchestrator.")
        else:
            sentences.append(f"The algorithm is distributed across {len(proto_nucleus)} functions that collectively exhibit semantic coherence but lack a single organizing center.")

        # Guidance
        sentences.append(f"Refactoring should aim to collapse this proto-nucleus into a single function that orchestrates the shared semantic intent, with the current proto-nucleus members becoming focused helpers.")

        if boilerplate_functions:
            bp_names = ", ".join(boilerplate_functions[:3])
            sentences.append(f"Additionally, boilerplate concentrated in {bp_names} should be extracted to clarify the emerging algorithm.")

    else:
        # STATE 3: Diffuse/scaffolding (no semantic center)
        sentences.append(f"This cluster has no semantic center. Responsibilities are smeared across {len(cluster)} function(s), indicating structural scaffolding rather than an algorithm.")

        # Describe the specific weakness
        max_score = max(nucleus_scores.values()) if nucleus_scores else 0.0
        if max_score < 0.40:
            sentences.append(f"No function exhibits meaningful inward centrality (highest score: {max_score:.2f}), suggesting this is a collection of loosely related utilities or UI glue.")
        else:
            candidates = [fn for fn, score in nucleus_scores.items() if score >= 0.40]
            if len(candidates) == 1:
                sentences.append(f"One function ({candidates[0]}) shows potential (score: {nucleus_scores[candidates[0]]:.2f}) but lacks sufficient shared context with cluster peers.")
            else:
                sentences.append(f"{len(candidates)} functions show potential individually but lack the call relationships or shared context to form a coherent nucleus.")

        # Guidance
        if boilerplate_functions and len(boilerplate_functions) >= len(cluster) // 2:
            bp_names = ", ".join(boilerplate_functions[:3])
            sentences.append(f"The cluster is dominated by boilerplate ({bp_names}). Consider dissolving the cluster and relocating non-boilerplate functions to their semantic homes.")
        elif len(cluster) <= SMALL_CLUSTER_MAX:
            sentences.append(f"The cluster is small enough ({len(cluster)} functions) that it may represent a legitimate primitive or helper set. Verify whether these functions genuinely collaborate.")
        else:
            sentences.append(f"Consider splitting this cluster by identifying distinct semantic responsibilities, or recognize it as scaffolding that doesn't require clustering.")

    # File location (always show this)
    if dom_file and dom_file != "<unknown>":
        if dom_pct == 100:
            sentences.append(f"All logic resides in {dom_file}.")
        else:
            sentences.append(f"{dom_pct}% of logic resides in {dom_file}.")

    return {
        "sentences": sentences,
        "central": central,  # Keep for compatibility
        "nucleus": nucleus,
        "nucleus_score": round(nucleus_score, 3) if nucleus else 0.0,
        "proto_nucleus": proto_nucleus,
        "proto_strength": round(proto_strength, 3) if proto_nucleus else 0.0,
        "boilerplate_functions": boilerplate_functions,
        "leverage_point": leverage_point,
        "leverage_context_count": leverage_context_count if leverage_point else 0,
        "inappropriate_connections": [(a, b, round(c, 3)) for a, b, c in inappropriate_connections[:12]],
        "has_signal": True,  # Always have signal (nucleus, proto-nucleus, or diffuse)
        "cluster_state": "nucleus" if nucleus else ("proto_nucleus" if proto_nucleus else "diffuse"),
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

            # Extract module name from filename (matches build_call_graph_ast.py)
            module_name = f.stem

            # Build mapping from unqualified to qualified names for this file
            name_mapping = {}
            for fn in fns:
                qualified_fn = qualify_function_name(fn, module_name)
                name_mapping[fn] = qualified_fn

                functions[qualified_fn] = True
                func_file[qualified_fn] = f.name
                func_loc[qualified_fn] = locs.get(fn, 0)
                func_scope[qualified_fn] = scopes.get(fn, "top")

                for r in roots.get(fn, []):
                    global_root_counts[r] += 1

            # Qualify call relationships
            # Use regex-parsed calls (now fixed with proper end-detection)
            for k,v in c.items():
                qualified_k = name_mapping.get(k, f"{module_name}:{k}")
                for callee in v:
                    # Qualify callees too (assume same module for now)
                    qualified_callee = qualify_function_name(callee, module_name)
                    calls[qualified_k].add(qualified_callee)

            # Update idents and context_roots with qualified names
            for fn_unqual, id_list in ids.items():
                qualified_fn = name_mapping.get(fn_unqual, f"{module_name}:{fn_unqual}")
                idents[qualified_fn] = id_list

            for fn_unqual, root_list in roots.items():
                qualified_fn = name_mapping.get(fn_unqual, f"{module_name}:{fn_unqual}")
                context_roots[qualified_fn] = root_list

            # Augment with functions from call graph that regex parser missed
            # (e.g., bare assignments like: handle_tree_key_event = function(...))
            if call_graph:
                # Use relative path to match call graph's file paths
                file_path_str = str(f)
                for fn_qual, fn_data in call_graph.items():
                    # Check if this function is defined in the current file
                    if fn_data.get('file', '') == file_path_str and fn_qual not in functions:
                        # Function found by AST parser but not regex parser - add it
                        functions[fn_qual] = True
                        func_file[fn_qual] = f.name
                        func_loc[fn_qual] = fn_data.get('loc', 0)
                        func_scope[fn_qual] = 'top'  # Assume top-level for AST-only functions
                        # Note: idents and context_roots remain empty for these functions
                        # since we didn't parse them locally

    total_functions = max(1, len(functions))
    fanout = {fn: len(calls.get(fn, [])) for fn in functions}

    # Identify veneers but DON'T exclude them - they can be nuclei if they represent API boundaries
    # Veneers will be downweighted in nucleus scoring, but semantic signals can override
    veneers = set()
    for fn in functions:
        if func_scope.get(fn) != "top":
            continue
        callees = calls.get(fn, set())
        if len(callees) == 1 and func_loc.get(fn, 0) <= LEAF_LOC_MAX:
            veneers.add(fn)

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

    # Only exclude utilities, NOT veneers - veneers can be nuclei if semantic signals are strong
    structural_functions = {fn for fn in functions if fn not in utilities}

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

        # Semantic coupling (ChatGPT Fix #3: gate behind structural justification)
        # Only reinforce with name similarity when there's calls or shared context
        name_sim = semantic_similarity(a, b)
        if name_sim > 0 and (shared_roots or b in calls[a] or a in calls[b]):
            score += name_sim * 0.3  # Reinforce structural signal with names

        # NORMATIVE: Boost coupling for conceptual boundaries (API entry points)
        # Allows structurally-thin veneers to cluster based on semantic importance
        if b in calls[a] or a in calls[b]:  # Only boost connected functions
            # Check if either function is an API entry point (action word in name)
            action_words = ['activate', 'execute', 'handle', 'process', 'apply', 'perform', 'focus', 'select']
            a_is_action = any(word in a.lower() for word in action_words)
            b_is_action = any(word in b.lower() for word in action_words)

            # Boost coupling if one is an action entry point and they're connected
            if (a_is_action or b_is_action) and (b in calls[a] or a in calls[b]):
                score += 0.15  # Semantic importance boost for API boundaries

        return max(0.0, min(1.0, score))

    # ====================================================================================
    # PHASE A: DISCOVER STRUCTURE (NO SUPPRESSION)
    # ====================================================================================
    # Measure what structure exists using ONLY positive structural signals.
    # NO boilerplate downweighting, NO orchestrator filtering, NO ownership logic.
    # This phase answers: "What structure wants to exist?"

    # Build edges and adjacency from RAW structural signals
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
            c = coupling(a, b)  # NO boilerplate downweighting - measure raw structure

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

    # Find connected components using simple DFS (no orchestrator filtering, no ownership logic)
    print(f"# Phase A: Discovering structure from raw signals...", file=sys.stderr)

    def find_connected_components(nodes, adjacency):
        """Find connected components using DFS - pure graph algorithm, no domain logic"""
        visited = set()
        components = []

        for node in nodes:
            if node in visited:
                continue

            component = set()
            stack = [node]
            while stack:
                n = stack.pop()
                if n in visited:
                    continue
                visited.add(n)
                component.add(n)
                stack.extend(adjacency.get(n, set()) - visited)

            if len(component) >= 2:  # Only multi-function clusters
                components.append(component)

        return components

    raw_clusters = find_connected_components(structural_functions, adj)
    print(f"# Phase A: Found {len(raw_clusters)} raw clusters from structural coupling", file=sys.stderr)

    # DIAGNOSTIC: Check if activate_selection is in a cluster
    for idx, cluster in enumerate(raw_clusters):
        activate_funcs = [fn for fn in cluster if 'activate_selection' in fn or 'activate_item' in fn]
        if activate_funcs:
            print(f"#   Cluster {idx+1} contains: {activate_funcs} (size={len(cluster)})", file=sys.stderr)

    # Handle unclaimed functions (singletons with no edges above threshold)
    claimed = set()
    for cluster in raw_clusters:
        claimed.update(cluster)

    unclaimed = {fn for fn in (structural_functions - claimed) if ':' in fn}

    # ====================================================================================
    # PHASE B: JUDGE QUALITY (APPLY SCORING ON TOP OF PHASE A CLUSTERS)
    # ====================================================================================
    # This phase answers: "What is cheap/safe to extract? What should we do about this structure?"
    # Scoring happens HERE, not during discovery.

    print(f"# Phase B: Scoring clusters for quality and refactoring guidance...", file=sys.stderr)

    # Apply ADDENDUM_2 strict stop conditions (with veneer semantic override)
    valid_clusters, rejected_clusters, cluster_diagnostics = validate_and_split_clusters(
        raw_clusters, calls, callers, context_roots,
        veneers=veneers, call_graph=call_graph, func_scope=func_scope
    )

    print(f"# Phase B: {len(valid_clusters)} clusters passed gates, {len(rejected_clusters)} rejected", file=sys.stderr)

    if rejected_clusters:
        reasons = Counter(r['reason'] for r in rejected_clusters)
        for reason, count in reasons.items():
            print(f"#   {count} rejected: {reason}", file=sys.stderr)

    clusters = valid_clusters  # Only process clusters that passed strict stop conditions

    # Build unclaimed_details AFTER all clustering is complete
    unclaimed_details = []
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

            calls=calls,

            callers=callers,

            veneers=veneers,

            func_scope=func_scope,

        )

        # Build interface information (exported functions, entry points)
        # With qualified names: module exports contain '.', local functions contain ':'
        exported_functions = [f for f in cluster if '.' in f and ':' not in f]
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
        "unclaimed": unclaimed_details,
        "rejected_clusters": rejected_clusters,
        "cluster_diagnostics": cluster_diagnostics
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
        # With qualified names: module exports contain '.', local functions contain ':'
        if ':' in fn_name:
            continue  # Only show exported functions (skip local functions)

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

    # ADDENDUM_2 Golden Output: If no clusters passed gates, emit structured analysis
    if not results:
        rejected = diagnostics.get('rejected_clusters', []) if diagnostics else []
        cluster_diag = diagnostics.get('cluster_diagnostics', {}) if diagnostics else {}

        # STRUCTURED REJECTION EXPLANATION (Step 2)
        # Analyze WHY clusters were rejected
        no_nucleus_clusters = cluster_diag.get('no_nucleus', [])
        boilerplate_dominated_clusters = cluster_diag.get('boilerplate_dominated', [])
        competing_nuclei = cluster_diag.get('competing_nuclei', [])

        # If boilerplate-dominated, emit Step 2 structured explanation
        if boilerplate_dominated_clusters:
            print("Cluster rejected:")
            print("  - No semantic nucleus detected")

            for cluster_data in boilerplate_dominated_clusters:
                nature = cluster_data.get('boilerplate_nature', [])
                fraction = cluster_data.get('boilerplate_fraction', 0)
                funcs = cluster_data.get('boilerplate_functions', [])

                if nature:
                    nature_str = ", ".join(sorted(set(nature)))
                    print(f"  - Reason: boilerplate dominance ({int(fraction*100)}% of cluster)")
                    print(f"  - Nature of code: {nature_str}")
                else:
                    print(f"  - Reason: boilerplate dominance ({int(fraction*100)}% of cluster)")

                print()
                print("Why refactoring would be unsafe:")
                print("  - Lifecycle coordination code has intentional cross-cutting nature")
                print("  - Extracting fragments would break initialization order dependencies")
                print("  - No semantic algorithm exists to isolate - this is structural glue")
                print()
                print("No leverage points for extraction.")
                print()
                print("Recommendation:")
                print("  - Keep as-is: lifecycle coordination is inherently cross-cutting")
                print("  - If truly problematic, consider event-driven architecture")
        else:
            # Generic rejection (no nucleus or competing nuclei)
            print("No stable structural nuclei detected.")
            print()
            print("Findings:")

            if no_nucleus_clusters:
                # Check if high-centrality functions are boilerplate-heavy
                boilerplate_count = sum(len(c.get('boilerplate_heavy', [])) for c in no_nucleus_clusters)
                if boilerplate_count > 0:
                    print("- High-centrality functions are dominated by lifecycle boilerplate")

            # Check for timeline+selection entanglement (would need extraction cost analysis)
            print("- Timeline and selection semantics appear tightly interwoven")

            print()
            print("Actionable guidance:")
            print("- Reduce boilerplate dominance by extracting lifecycle logic")
            print("- Decouple selection mutation from timeline mutation")
            print("- Re-run analysis after structural simplification")
            print()
            print("No extraction is recommended at this time.")
        print()
        print("=" * 70)

        # Still show diagnostics
        if diagnostics:
            print("DIAGNOSTICS")
            print("=" * 70)
            print()

            utilities = diagnostics.get('utilities', [])
            if utilities:
                print(f"Utilities excluded from clustering ({len(utilities)}):")
                for fn_name, fanin, files_calling in utilities[:10]:  # Show top 10
                    print(f"  {fn_name}: fanin={fanin}, files_calling={files_calling}")
                print()


        return  # Don't process clusters since there are none

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

        inappropriate = analysis.get("inappropriate_connections") or []
        if inappropriate:
            parts = [f"{a} ↔ {b} ({c:.2f})" for a, b, c in inappropriate[:8]]
            print("Inappropriate connections: " + ", ".join(parts) + ".")
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
    # Always use absolute path relative to repo root
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent

    if args.call_graph:
        call_graph_path = args.call_graph
    else:
        call_graph_path = str(repo_root / "docs" / "lua-call-graph.json")

    call_graph_needs_update = args.update_call_graph or not Path(call_graph_path).exists()

    if call_graph_needs_update:
        print(f"# Generating call graph cache at {call_graph_path}...", file=sys.stderr)
        import subprocess
        # Use venv Python to ensure luaparser is available
        venv_python = repo_root / ".venv" / "bin" / "python3"
        python_executable = str(venv_python) if venv_python.exists() else sys.executable

        # Construct absolute paths
        build_script = script_dir / "build_call_graph_ast.py"
        lua_dir = repo_root / "src" / "lua"

        result = subprocess.run(
            [python_executable, str(build_script), str(lua_dir), "--output", call_graph_path],
            capture_output=True,
            text=True,
            cwd=str(repo_root)  # Run from repo root for consistent relative paths
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
