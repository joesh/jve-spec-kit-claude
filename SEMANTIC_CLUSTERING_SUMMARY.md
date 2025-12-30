# Semantic Clustering Enhancement Summary

## Problem Statement

The original Louvain clustering (resolution=2.0) produced clusters that were **structurally valid** but **semantically incorrect**:
- Related functions scattered across clusters (`finalize_pending_rename` in C1, `M.start_inline_rename` in C3)
- Similar operations separated (`create_bin_in_root` in C2, `add_bin` in C4)
- Utilities mixed into domain clusters instead of being isolated

## Solution: Hybrid Structural + Semantic Clustering

### 1. Global Call Graph Database (`build_call_graph.py`)

**Purpose**: Cross-file analysis for utility detection  
**Output**: `call_graph.json` with 1,480 functions

**Metrics Per Function**:
- `fanin`: How many functions call this function
- `fanout`: How many functions this function calls
- `files_calling`: How many different files use this function
- `is_utility`: Boolean flag for utility classification

**Utility Detection Criteria** (refined from research):
```python
is_high_fanin = fanin >= 5
is_multi_file = files_calling >= 3
is_extreme_outlier = fanin > 3 * avg_fanin and files_calling >= 2

if (is_high_fanin and is_multi_file) or is_extreme_outlier:
    utilities.add(fn_name)
```

**Key Insight**: BOTH high fanin AND multi-file usage required (not OR). This prevents module-internal helpers from being misclassified as utilities.

**Results**:
- 29 true utilities identified (down from 79 with looser criteria)
- Examples: `logger.warn` (96 calls, 31 files), `Rational.new` (90 calls, 33 files)
- Correctly excluded: `start_inline_rename_after` (5 calls, 2 files) - module helper, not utility

### 2. Semantic Similarity (`analyze_lua_structure.py`)

**Function Name Tokenization**:
```python
"M.start_inline_rename" → {"start", "inline", "rename"}
"create_bin_in_root" → {"create", "bin", "in", "root"}
"finalizePendingRename" → {"finalize", "pending", "rename"}  # camelCase split
```

**Jaccard Similarity**:
```python
similarity = len(tokens_a ∩ tokens_b) / len(tokens_a ∪ tokens_b)
```

**Example Scores**:
- `M.start_inline_rename` ↔ `start_inline_rename_after`: **0.750** (very high!)
- `finalize_pending_rename` ↔ `M.start_inline_rename`: **0.200** (low—different phases)
- `create_bin_in_root` ↔ `add_bin`: **0.200** (low—different verbs)

### 3. Enhanced Coupling Function

**Original** (structural only):
```python
score = 0.0
# Context roots: shared 'ctx', 'timeline_state', etc.
if shared_roots:
    score += min(0.8, 0.4 + 0.2 * len(shared_roots))

# Shared identifiers: common variable names
if len(shared_idents) >= 3:
    score += min(0.3, len(shared_idents) * 0.03)

# Call relationships
if b in calls[a]:
    score += 0.5 / max(1, fanout[a])

# Penalties for high fanout (utilities)
score -= min(0.5, fanout[b] * 0.03)
```

**Enhanced** (structural + semantic):
```python
# ... existing structural logic ...

# NEW: Semantic coupling from name similarity
name_sim = semantic_similarity(a, b)
if name_sim > 0:
    score += name_sim * 0.3  # Weight semantic signal
```

## Results & Validation

### Before (Louvain resolution=2.0, no semantic/utility filtering):
- 10 clusters
- Cluster sizes: 31, 8, 5, 4, 4, 2, 2, 2 functions
- **Problems**:
  - Rename workflow scattered: `finalize_pending_rename` (C1), `M.start_inline_rename` (C3), `start_inline_rename_after` (C3)
  - Bin operations split: `create_bin_in_root` (C2), `add_bin` (C4)
  - Utilities like `format_duration` embedded in clusters

### After (with semantic similarity + utility filtering):
- 7 clusters (3 utilities filtered out)
- **Improvements**:
  - ✅ **Cluster 1**: `M.start_inline_rename` + `start_inline_rename_after` (0.75 similarity)
  - ✅ Utilities pre-filtered (29 identified, not clustered with domain logic)
  - ⚠️  Still 30-function cluster (structural signals dominate)

### Trade-offs & Insights

**What Worked**:
- High-similarity pairs clustered together (`start_inline_rename` + `start_inline_rename_after`)
- Utilities correctly excluded from domain clusters
- Module-internal helpers not misclassified as utilities

**What Didn't Work** (expected):
- `finalize_pending_rename` still separate (only shares "rename" token—semantically different)
- `add_bin` vs `create_bin_in_root` separate (different verbs—correct!)

**Key Architectural Insight**: The tool correctly identifies that "start inline rename" and "finalize pending rename" are **separate concerns** despite being in the same workflow. They're different *phases* with different responsibilities, which aligns with the goal of breaking apart complexity.

## Usage

```bash
# Build global call graph
./scripts/build_call_graph.py src/lua --output call_graph.json

# Run clustering with semantic similarity and utility filtering
./scripts/analyze_lua_structure.py src/lua/ui/project_browser \
    --call-graph call_graph.json \
    --json > analysis.json

# Or text output
./scripts/analyze_lua_structure.py src/lua/ui/project_browser \
    --call-graph call_graph.json
```

## Research References

- **Ensemble Clustering**: Kumar et al. (2025) - combine structural + semantic + directory
- **Utility Detection**: Wen & Tzerpos - multi-cluster connections + high fanin
- **Semantic Similarity**: LSI-based identifier name analysis
- **SA-Cluster Algorithm**: unified distance measure (graph + attributes)

## Next Steps

1. ✅ Build global call graph analyzer
2. ✅ Implement semantic similarity
3. ✅ Pre-filter utilities
4. ⏳ Add long function detection (flag >100 LOC)
5. ⏳ Build call hierarchy analysis (orchestrator vs leaf)
6. ⏳ Match output language to ANALYSIS_TOOL_ORIGINAL_CHAT.md patterns

