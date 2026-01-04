# Golden Test 1: Regression Test Specification

**Status**: FROZEN (Contract-Level Guarantee)
**Last Updated**: 2026-01-04
**Freeze Commit**: 95468d6

## Purpose

This document defines the authoritative expected behavior for Golden Test 1, which validates:
1. Nucleus detection via semantic centrality
2. Leverage point detection via context-breadth heuristic
3. Context root taxonomy (4 types)
4. Utility filtering (boilerplate exclusion)

**Any changes to context detection rules MUST NOT alter these results without explicit specification update.**

---

## Test Input

**File**: `project_browser.lua`
**Analysis Scope**: Single-file module with 7 functions in cluster
**Tool**: `scripts/analyze_lua_structure.py`

### Expected Cluster Members (7 functions):
1. `project_browser.activate_selection` ← **Nucleus**
2. `project_browser.get_selected_item`
3. `project_browser:activate_item`
4. `project_browser:apply_single_selection`
5. `project_browser:handle_tree_item_changed`
6. `project_browser:selection_context`
7. `project_browser:update_selection_state` ← **Leverage Point**

### Expected Exclusions:
- **Utility**: `project_browser.refresh` (fanin=7, files_calling=3, boilerplate ≥ 0.6)

---

## Expected Results

### Nucleus Detection

**Function**: `project_browser.activate_selection`

**Nucleus Score**: ≥ 0.42 (actual: ~0.545)

**Justification**:
- Module API (public interface via `.` notation)
- Semantic centrality dominates (60% weight)
- Low boilerplate score
- Clear responsibility center

**Context Roots**: 2 distinct contexts
- `M` (table access)
- `get_selected_item` (context constructor)

### Leverage Point Detection

**Function**: `project_browser:update_selection_state`

**Context Count**: 4 distinct contexts (exceeds nucleus count of 2)

**Detected Contexts**:
1. `browser_state` (table access)
2. `is_restoring_selection` (lifecycle guard)
3. `selection_context` (context constructor)
4. `update_selection_state` (state mutation invocation)

**Justification**:
> "The primary leverage point is project_browser:update_selection_state, which touches 4 distinct contexts (nucleus: 2). Extracting project_browser:update_selection_state into a focused module would reduce the nucleus's context dependencies and improve separation of concerns."

**Boilerplate Score**: < 0.6 (non-boilerplate function)

---

## Context Root Taxonomy (FROZEN CONTRACT)

This taxonomy is **authoritative** and changes to detection patterns MUST NOT alter Golden Test 1 results.

### 1. Table/Module Access

**Pattern**: `[\.:][a-zA-Z_][a-zA-Z0-9_]*`
**Regex**: `\b([a-zA-Z_][a-zA-Z0-9_]*)[\.:][a-zA-Z_][a-zA-Z0-9_]*`

**Examples**:
- `browser_state.update_selection_state` → captures `browser_state`
- `M.activate_selection` → captures `M`
- `self:apply_single_selection` → captures `self` (filtered if in stopwords)

**Stopword Filtering**: YES (exclude `self`, common Lua keywords)

### 2. Lifecycle Guard

**Pattern**: Identifiers in conditional contexts matching lifecycle keywords

**Detection Contexts**:
- `if <identifier> then`
- `while <identifier> do`
- `<identifier> and`
- `<identifier> or`
- `not <identifier>`

**Required Keywords** (any substring match):
```
is_, has_, should_, can_, enabled, disabled, loading, restoring, pending
```

**Regex Patterns**:
```python
r'\bif\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+then'
r'\bwhile\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+do'
r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s+and\b'
r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s+or\b'
r'\bnot\s+([a-zA-Z_][a-zA-Z0-9_]*)\b'
```

**Example**: `if is_restoring_selection then` → captures `is_restoring_selection`

**Stopword Filtering**: YES (exclude single-letter loop variables: i, j, k, v, x, y, n)

### 3. Context Constructor

**Pattern**: Function calls matching context retrieval keywords

**Detection Pattern**: `<identifier>()` where identifier contains keyword

**Required Keywords** (substring match):
```
context, state, get_, fetch_, load_, find_, selected, current
```

**Regex**: `r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\('`

**Examples**:
- `selection_context()` → captures `selection_context`
- `get_selected_item()` → captures `get_selected_item`
- `fetch_user_state()` → captures `fetch_user_state`

**Stopword Filtering**: YES (exclude Lua built-ins like `print`, `error`)

### 4. State Mutation Invocation

**Pattern**: Function calls on table members (delegation pattern)

**Coverage**: Captured by Type 1 (table access) + Type 3 (context constructor)

**Example**: `browser_state.update_selection_state()` → captures both:
- `browser_state` (table access)
- `update_selection_state` (context constructor via `state` keyword)

**NOT Recursion**: This is delegation to an authoritative state writer, not self-reference.

---

## Regression Assertions

### CRITICAL: Leverage Point Stability

**Assertion**: If context detection rules are unchanged, leverage point MUST remain `project_browser:update_selection_state`.

**Failure Criteria**:
- Leverage point changes to different function
- Leverage point context count drops below 4
- Leverage point becomes `None` (no detection)

**Action on Failure**:
- HALT: This indicates regression in context detection
- Review changes to `extract_context_roots()` function
- Verify taxonomy patterns match frozen specification

### Context Count Stability

**Nucleus Contexts**: MUST = 2
- `M`
- `get_selected_item`

**Leverage Contexts**: MUST = 4
- `browser_state`
- `is_restoring_selection`
- `selection_context`
- `update_selection_state`

**Failure Criteria**: Count changes without taxonomy modification

### Nucleus Stability

**Assertion**: `project_browser.activate_selection` remains nucleus

**Failure Criteria**:
- Different function becomes nucleus
- No nucleus detected (cluster rejected)
- Nucleus score falls below 0.42

### Utility Exclusion Stability

**Assertion**: `project_browser.refresh` excluded from clustering

**Criteria**: fanin ≥ 7, files_calling ≥ 3, boilerplate ≥ 0.6

---

## Implementation Reference

### Context Detection Code Location

**File**: `scripts/analyze_lua_structure.py`
**Function**: `extract_context_roots(text)` (lines 76-120)

### Leverage Point Detection Code Location

**File**: `scripts/analyze_lua_structure.py`
**Function**: `analyze_cluster()` Phase 4 (lines 944-993)

### Key Parameters (Frozen)

```python
NUCLEUS_THRESHOLD = 0.42  # Minimum score for nucleus candidacy
BOILERPLATE_EXCLUSION = 0.6  # Maximum boilerplate for leverage candidates
CLUSTER_THRESHOLD = 0.25  # Minimum coupling for cluster membership
```

### Semantic Centrality Weights

```python
raw_signal = (
    0.15 * inward_call_weight +
    0.10 * shared_context_weight +
    0.15 * internal_participation +
    0.60 * semantic_centrality  # Dominates structural metrics
)
```

---

## Running Golden Test 1

### Command

```bash
cd /Users/joe/Local/jve-spec-kit-claude
python3 scripts/analyze_lua_structure.py project_browser.lua > /tmp/golden_test_1_output.txt
```

### Success Criteria

Output MUST contain:

```
CLUSTER 1
Type: Algorithm

InternalComponent of project_browser.lua.

Analysis:
This cluster has a clear nucleus around project_browser.activate_selection, indicating a coherent algorithm.
The primary leverage point is project_browser:update_selection_state, which touches 4 distinct contexts (nucleus: 2).
Extracting project_browser:update_selection_state into a focused module would reduce the nucleus's context dependencies and improve separation of concerns.
All logic resides in project_browser.lua.
```

### Validation Checklist

- [ ] Nucleus = `project_browser.activate_selection`
- [ ] Nucleus contexts = 2
- [ ] Leverage point = `project_browser:update_selection_state`
- [ ] Leverage contexts = 4
- [ ] Utility excluded = `project_browser.refresh`
- [ ] Cluster size = 7 functions
- [ ] Recommendation = "Extracting [leverage_point] into a focused module..."

---

## Change Control

### Allowed Changes (No Regression)

1. **Performance optimizations** to context detection (caching, memoization)
2. **Code refactoring** that preserves detection patterns
3. **Output formatting** improvements (cosmetic only)
4. **Additional context types** IF they don't alter Golden Test 1 results

### Prohibited Changes (Regression)

1. **Altering taxonomy keywords** (lifecycle guards, context constructors)
2. **Changing regex patterns** for table access or function calls
3. **Modifying stopword lists** that affect Golden Test 1 functions
4. **Adjusting nucleus/boilerplate thresholds** without specification update
5. **Removing any of the 4 context types** from detection

### Specification Update Process

If legitimate tool improvements require changing Golden Test 1 results:

1. **Document rationale** for taxonomy change
2. **Update this specification** with new expected results
3. **Increment specification version** (currently v1.0)
4. **Re-baseline all golden tests** to new taxonomy
5. **Commit specification and code changes together**

---

## Appendix: Full Cluster Output

```
Functions:
project_browser.activate_selection
project_browser.get_selected_item
project_browser:activate_item
project_browser:apply_single_selection
project_browser:handle_tree_item_changed
project_browser:selection_context
project_browser:update_selection_state

Interface:
  project_browser.activate_selection  [called internally]
  project_browser.get_selected_item

Files:
project_browser.lua: 100%

Diagnostics:
Utilities excluded from clustering (1):
  project_browser.refresh: fanin=7, files_calling=3
```

---

## Version History

**v1.0** (2026-01-04, Commit 95468d6):
- Initial freeze after implementing semantic context expansion
- Context taxonomy: 4 types (table access, lifecycle guard, context constructor, state mutation)
- Leverage point detection via context-breadth heuristic
- Nucleus detection via semantic centrality (60% weight)
