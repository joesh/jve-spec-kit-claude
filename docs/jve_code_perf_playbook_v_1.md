# JVE Code & Perf Playbook

_Last updated: Nov 10, 2025_

## 1) Self-Documenting Code

### Top-Down Structure
- **Toplevel**: HLL pseudocode narrating the algorithm. Keep it current.
  - File: `timeline_toplevel.lua` or `timeline_algorithm.lua`
- **Mid-levels (3–4 max)**: Turn abstract steps into function names that encode **contracts** (pre/postconditions, invariants), not mechanics.
  - Files: `timeline_level2helpers.lua`, `timeline_level3helpers.lua`, etc.
- **Leaves**: Tiny, reusable, algorithm-agnostic routines.
  - File: `timeline_leaves.lua` — all simple leaves live here to make patterns easy to scan and refactor.

### Naming Rules
- Prefer **domain verbs/nouns**; avoid generic terms like “helpers.”
  - ✅ `assign_tracks_by_priority()`
  - ❌ `sort_then_pack_tracks()`
- Convey **what** and **guarantees**, not **how**.
- Function header comment (1–2 lines): inputs → outputs; invariants.

### In-File HLL Spec
```lua
-- HLL: Rebuild timeline tracks
-- 1) gather_segments()
-- 2) bundle_by_priority()
-- 3) assign_tracks_by_priority()
-- 4) emit_track_layout()
```
Update the HLL block whenever structure changes.

### Depth & Layout Limits
- Max depth: **4** levels from toplevel to leaf.
- Max function cyclomatic complexity: **10** (warn > 8).
- No anonymous one-off “helper” functions in toplevel or algorithm files.

### Tests by Level
- **Toplevel** = scenario/black-box tests.
- **Mid-level** = contract tests (pre/post/invariants).
- **Leaves** = property/parametric tests.

---

## 2) Performance Discipline

### Algorithm class first (explicit policy)
1. **Pick the asymptotics up front.** Default target is **O(N log N)** or better in hot paths. If an **O(N²)** (or worse) choice is acceptable due to bounded data sizes or usage patterns, add an **N² Waiver** to the PR:
   - **Ceiling**: max N (and why it’s stable) 
   - **Budget math**: measured ms vs. target on representative data
   - **Inputs**: distributions that make it safe (e.g., short bins, capped fan‑out)
   - **Guardrails**: thresholds that flip to a better algorithm (feature flag)
   - **Test**: CI perf test asserting the ceiling

2. **Then measure.** Profilers are flaky right now; until they’re solid, collect **timing counters** instead of flamegraphs:
   - Add a minimal timer wrapper (hrtime) around candidate hot sections; emit CSV to `/perf/samples/` per commit.
   - Log **call counts + bytes/objects processed** alongside ms so regressions are diagnosable.
   - When profiler support improves, attach flamegraphs, but don’t block on them.

3. **Reduce allocations/GC churn.**
4. **Optimize data layout** (arrays over maps where possible).
5. **Stabilize types/branches** for the JIT.
6. Micro‑opt only after 1–5.

### Practical profiling now (Lua)
- **No‑block path** (works today): inline timers + counters.
  ```lua
  local hrtime = require('hrtime') -- or a thin FFI wrapper; fallback to os.clock
  local t0 = hrtime.now()
  hot_path()
  perf.log('hot_path', hrtime.since(t0), items_processed)
  ```
- **LuaJIT (if available):** try `require('jit.p').start('f')` → run → `jit.p.stop()`. If that’s unstable, fall back to timers.
- **PUC‑Lua:** `ProFi` (pure Lua) or a `debug.sethook` sampler; store outputs under `/perf/samples/`. 

### Tooling & CI
- **Perf tests** with thresholds; fail on regression.
- Accept **timing CSVs** or profiles; flamegraphs optional.
- Feature flags to compare **reference** vs **optimized** paths.

---

## 3) Lightweight Policy Checks (Automatable)
- Reject files that:
  - exceed depth limits or complexity caps;
  - introduce `*_level5*.lua` (or deeper);
  - add string creation in hot loops (`concat`, `format`, `..`) without justification.
- Enforce 1–2 line **contract headers** per public function.

- Reject files that:
  - exceed depth limits or complexity caps;
  - introduce `*_level5*.lua` (or deeper);
  - add string creation in hot loops (`concat`, `format`, `..`) without justification.
- Enforce 1–2 line **contract headers** per public function.

---

## 4) File Map (suggested)
```
/timeline/
  timeline_toplevel.lua        -- HLL pseudocode + orchestration
  timeline_level2helpers.lua   -- second-level contracts
  timeline_level3helpers.lua   -- third-level contracts
  timeline_leaves.lua          -- all simple reusable leaves
  perf/                        -- budgets, traces, flamegraphs
  tests/
    scenario_spec.lua          -- toplevel scenarios
    contracts_spec.lua         -- mid-level contracts
    props_spec.lua             -- leaves properties
```

---

## 5) Quick Checklist
- [ ] HLL block present & current in toplevel.
- [ ] Depth ≤ 4; names encode contracts; no “helpers.”
- [ ] Perf budgets defined; latest flamegraph checked in.
- [ ] Hot paths: arrays, stable types, minimal allocations.
- [ ] Tests pass at all levels; CI perf thresholds green.

