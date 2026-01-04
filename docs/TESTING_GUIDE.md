# Testing Guide: Structural Analysis Tool

## Quick Start

### Run Golden Test 1 (Regression Test)

```bash
python3 scripts/validate_golden_test_1.py
```

**Expected Output**:
```
✅ ALL ASSERTIONS PASSED

Golden Test 1 validates:
  ✓ Nucleus detection: project_browser.activate_selection
  ✓ Nucleus contexts: 2
  ✓ Leverage point: project_browser:update_selection_state
  ✓ Leverage contexts: 4
  ✓ Utility exclusion: project_browser.refresh
  ✓ Cluster size: 7 functions
```

**Exit Codes**:
- `0`: All assertions passed
- `1`: Validation failure (regression detected)
- `2`: Test infrastructure error (file not found, parse error)

---

## Golden Tests Overview

Golden tests are **frozen regression tests** that validate critical tool behavior remains stable across code changes. They define the **contract** between the analysis tool and its users.

### Golden Test 1: Nucleus and Leverage Point Detection

**Purpose**: Validates context-breadth heuristic and semantic centrality scoring

**Test File**: `project_browser.lua`

**Specification**: `docs/GOLDEN_TEST_1_SPECIFICATION.md`

**What It Tests**:
1. **Nucleus Detection**: Semantic center identified via API-level importance (60% weight)
2. **Leverage Point Detection**: Cross-cutting function identified via context-breadth rule
3. **Context Taxonomy**: 4 types correctly detected (table access, lifecycle guard, context constructor, state mutation)
4. **Utility Filtering**: High-boilerplate functions excluded from clustering

**Why It Matters**:
- Prevents regressions in context detection (most fragile part of analysis)
- Validates that semantic centrality dominates structural metrics
- Ensures leverage points represent extraction opportunities, not noise
- Guards against accidental threshold changes

**When to Run**:
- Before committing changes to `analyze_lua_structure.py`
- After modifying `extract_context_roots()` function
- After adjusting nucleus/boilerplate thresholds
- As part of CI/CD pipeline (pre-merge check)

---

## Manual Testing

### Test Single File

```bash
python3 scripts/analyze_lua_structure.py <file.lua>
```

**Example**:
```bash
python3 scripts/analyze_lua_structure.py project_browser.lua > /tmp/output.txt
```

### Test Full Codebase

```bash
python3 scripts/analyze_lua_structure.py src/lua/**/*.lua > /tmp/full_analysis.txt
```

**Expected Behavior**:
- 15-25% cluster pass rate (healthy signal-to-noise ratio)
- 75-85% rejection rate (mostly "no_nucleus")
- Utilities correctly excluded (fanin ≥ 7, files_calling ≥ 3)

### Visual Inspection Checklist

For each cluster output:
- [ ] **Nucleus**: Should be module API or semantic center (not just high fan-in)
- [ ] **Leverage Point**: Should touch more contexts than nucleus (extraction opportunity)
- [ ] **Cluster Type**: Algorithm (coherent), Proto-nucleus (emergent), or Diffuse (rejected)
- [ ] **Guidance**: Actionable recommendation (extract, consolidate, clarify)
- [ ] **Interface**: Public API clearly separated from internal functions

---

## Debugging Failed Tests

### Golden Test 1 Failure: "LEVERAGE POINT CHANGED"

**Symptoms**:
```
❌ VALIDATION FAILED
  • LEVERAGE POINT CHANGED: Expected 'project_browser:update_selection_state', got 'project_browser.get_selected_item'
```

**Root Causes**:
1. **Context taxonomy regression**: One of the 4 context types stopped being detected
2. **Threshold change**: `BOILERPLATE_EXCLUSION` increased, filtering out true leverage point
3. **Stopword addition**: New stopword filtering excluded context root identifier
4. **Regex pattern change**: Table access or function call patterns no longer match

**Diagnostic Steps**:

1. **Check context counts manually**:
   ```bash
   python3 scripts/analyze_lua_structure.py project_browser.lua 2>&1 | grep "contexts:"
   ```

   Expected:
   ```
   update_selection_state: 4 contexts
   activate_selection: 2 contexts
   ```

2. **Inspect detected context roots** (add debug output to `extract_context_roots()`):
   ```python
   def extract_context_roots(text):
       roots = set()
       # ... detection logic ...
       print(f"DEBUG: Detected roots: {roots}")  # Add this
       return roots
   ```

3. **Verify taxonomy patterns** against `GOLDEN_TEST_1_SPECIFICATION.md`:
   - Lines 76-120: Context detection patterns
   - Lines 92-108: Lifecycle guard keywords
   - Lines 110-118: Context constructor keywords

4. **Check threshold values**:
   ```python
   NUCLEUS_THRESHOLD = 0.42  # Must be ≤ 0.42
   BOILERPLATE_EXCLUSION = 0.6  # Must be = 0.6
   ```

**Resolution**:
- If unintentional: Revert context detection changes
- If intentional: Update `GOLDEN_TEST_1_SPECIFICATION.md` and `validate_golden_test_1.py`

### Cluster Size Changed

**Symptoms**:
```
❌ VALIDATION FAILED
  • CLUSTER SIZE CHANGED: Expected 7, got 5
  • CLUSTER MISSING FUNCTIONS: {'project_browser:update_selection_state', 'project_browser:selection_context'}
```

**Root Causes**:
1. **Clustering threshold increased**: Functions no longer meet coupling threshold
2. **Call graph extraction bug**: Parser missing function calls
3. **Scope detection changed**: Functions now classified as different scope

**Resolution**: Check `CLUSTER_THRESHOLD = 0.25` and verify parser extracts all function calls

---

## Test-Driven Development Workflow

### Adding New Context Types

**Goal**: Extend context taxonomy to detect new patterns (e.g., error handlers)

**Process**:

1. **Write failing test case** first:
   ```python
   # In validate_golden_test_1.py
   EXPECTED_LEVERAGE_CONTEXTS = 5  # Was 4, now should detect error handlers
   ```

2. **Implement detection pattern**:
   ```python
   # In analyze_lua_structure.py extract_context_roots()
   if 'error' in func_name or 'handle_' in func_name:
       roots.add(func_name)
   ```

3. **Run validation**:
   ```bash
   python3 scripts/validate_golden_test_1.py
   ```

4. **Verify new context appears** in output:
   ```
   Leverage: project_browser:update_selection_state (contexts: 5)
   ```

5. **Update specification**: Document new context type in `GOLDEN_TEST_1_SPECIFICATION.md`

### Tuning Nucleus Scoring Weights

**Goal**: Adjust semantic centrality weight from 60% to 70%

**Process**:

1. **Backup current output**:
   ```bash
   python3 scripts/validate_golden_test_1.py > /tmp/before.txt
   ```

2. **Change weight**:
   ```python
   raw_signal = (
       0.15 * inward_call_weight +
       0.10 * shared_context_weight +
       0.05 * internal_participation +
       0.70 * semantic_centrality  # Increased from 0.60
   )
   ```

3. **Run validation**:
   ```bash
   python3 scripts/validate_golden_test_1.py
   ```

4. **If Golden Test 1 still passes**: Change is backward-compatible ✅

5. **If failed**: Document breaking change, update specification version

---

## CI/CD Integration

### Pre-Commit Hook

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
# Run Golden Test 1 before allowing commit

if git diff --cached --name-only | grep -q "scripts/analyze_lua_structure.py"; then
    echo "Running Golden Test 1 (analyze_lua_structure.py changed)..."
    python3 scripts/validate_golden_test_1.py
    if [ $? -ne 0 ]; then
        echo "COMMIT BLOCKED: Golden Test 1 failed"
        echo "See validation output above for details"
        exit 1
    fi
fi
```

### GitHub Actions Example

```yaml
name: Golden Tests

on:
  pull_request:
    paths:
      - 'scripts/analyze_lua_structure.py'
      - 'scripts/validate_golden_test_1.py'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.9'
      - name: Run Golden Test 1
        run: python3 scripts/validate_golden_test_1.py
```

---

## Coverage Analysis

### What Golden Test 1 Covers

✅ **Context Detection**:
- Table access patterns
- Lifecycle guards in conditionals
- Context constructor function calls
- State mutation invocations

✅ **Nucleus Scoring**:
- Semantic centrality calculation (60% weight)
- Module API detection (`.` vs `:` notation)
- Cross-file caller bonus
- Boilerplate suppression

✅ **Leverage Point Detection**:
- Context-breadth heuristic (exceeds nucleus count)
- Boilerplate filtering (score ≥ 0.6)
- Tiebreaker by nucleus score

✅ **Utility Filtering**:
- High fanin detection (≥ 7 callers)
- Cross-file usage (≥ 3 files)
- Boilerplate score threshold

### What It Doesn't Cover

❌ **Multi-file clusters**: Golden Test 1 is single-file only
❌ **Proto-nucleus detection**: No proto-nucleus in test case
❌ **Competing nuclei rejection**: Test has clear single nucleus
❌ **Dead code detection**: All functions in cluster are claimed
❌ **Cross-module recommendations**: Test is self-contained module

### Future Golden Tests

**Recommended additions**:

1. **Golden Test 2**: Multi-file cluster with cross-module dependencies
2. **Golden Test 3**: Proto-nucleus case (2-5 functions, no dominant center)
3. **Golden Test 4**: Competing nuclei rejection (2+ strong candidates)
4. **Golden Test 5**: Utility-heavy module (multiple high-fanin functions)

---

## Troubleshooting

### "Analyzer not found" Error

**Cause**: Script path resolution issue

**Fix**:
```bash
cd /Users/joe/Local/jve-spec-kit-claude  # Run from repo root
python3 scripts/validate_golden_test_1.py
```

### "Test file not found" Error

**Cause**: `project_browser.lua` not in expected location

**Fix**: Check file exists at repo root:
```bash
ls -l project_browser.lua
```

If missing, validation script expects it at: `<repo_root>/project_browser.lua`

### Parse Errors

**Cause**: Analyzer output format changed

**Fix**: Update regex patterns in `parse_analysis_output()` to match new format

---

## Best Practices

### 1. Run Tests Locally Before Committing

```bash
# Quick pre-commit check
python3 scripts/validate_golden_test_1.py && git commit
```

### 2. Add Debug Output Temporarily

```python
# In extract_context_roots()
print(f"DEBUG [{fn_name}]: {len(roots)} contexts = {roots}")
```

Run test, then remove debug output before committing.

### 3. Document Breaking Changes

If Golden Test 1 must change:
1. Update `GOLDEN_TEST_1_SPECIFICATION.md` with rationale
2. Increment version (v1.0 → v2.0)
3. Update `validate_golden_test_1.py` expected values
4. Commit specification + code + test together

### 4. Keep Tests Fast

- Golden Test 1 runtime: < 1 second
- Full codebase analysis: < 10 seconds
- Tests should be runnable on every commit

---

## Summary

**Essential Commands**:
```bash
# Run regression test (most important)
python3 scripts/validate_golden_test_1.py

# Analyze single file manually
python3 scripts/analyze_lua_structure.py project_browser.lua

# Analyze full codebase
python3 scripts/analyze_lua_structure.py src/lua/**/*.lua > analysis.txt
```

**When to Run Tests**:
- ✅ Before every commit touching `analyze_lua_structure.py`
- ✅ After modifying context detection patterns
- ✅ After adjusting thresholds or weights
- ✅ As part of pull request validation

**On Test Failure**:
1. Read validation error messages carefully
2. Check `GOLDEN_TEST_1_SPECIFICATION.md` for contract
3. Debug with manual analysis + debug prints
4. Decide: revert change OR update specification
