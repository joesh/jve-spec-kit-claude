# ENGINEERING.md Compliance Audit — Plan

Status: PROPOSED (unresolved questions at bottom)
Scope: whole codebase review against `ENGINEERING.md` + `CLAUDE.md` rules.

## Context

- `ENGINEERING.md` has ~40 enforceable rules across two classes:
  - **Statically-greppable**: fallbacks, `print`, marketing words, bare Qt calls, stub returns, banned words.
  - **Semantic**: MVC push vs pull, FFI vs business-logic separation, functions-as-algorithms, test-domain-vs-implementation.
  Static passes are cheap and parallelizable; semantic passes need a reviewer-in-the-loop per subsystem.
- Codebase is ~112k LoC across 369 files (`src/lua` ~88k, `src/**.{cpp,h}` ~24k). Too large for one linear pass; review must be sharded.
- "Compliance" is a ranking problem, not binary. Output is a **prioritized issue ledger** (severity × blast radius), not a pass/fail cert.

## Phase 0 — Scaffolding (~30 min)

1. Create `AUDIT/` (gitignored) with `findings.md` ledger + per-rule / per-subsystem subfiles.
2. Severity scale:
   - **P0** crash / data-loss risk
   - **P1** violates fail-fast or MVC
   - **P2** style / naming / marketing
   - **P3** dead code / cleanup
3. Scope: `src/lua/**`, `src/**/*.{cpp,h}`. Exclude `build/`, `tests/captures/`, vendored (`dkjson`, `lsqlite3`, `uuid`, `tinytoml`).

## Phase 1 — Static Grep Passes

Each rule → one `AUDIT/rule_XX.md` with hit list + triage. Runnable in parallel.

| Rule | Pattern | What to flag |
|---|---|---|
| 1.14 / 2.13 | `\bor\s+(0\|nil\|""\|\{\}\|false)\b` in Lua; `??`, `value_or(` in C++ | Fallback defaults on required data |
| 1.14 | `if\s+\w+\s+then` wrapping required-data use | Silent skip instead of assert |
| 2.1 / 3.14 | `professional\|robust\|powerful\|enterprise\|amazing\|seamless\|blazing` | Marketing speak |
| 2.17 | `-- TODO`, `-- stub`, `return true -- stub`, `NotImplemented` | Stubs |
| 1.10 / 2.18 | Business-logic files calling Qt C++ directly (not via `qt_bindings/`) | Layer violation |
| 2.5 / 2.6 | Lua functions >60 lines; files >800 lines | Monoliths — split candidates |
| logger | bare `print(` outside `tests/`, `--test` harness, debug scripts | Logger bypass |
| 2.29 | Commands without `sequence_id` in spec | Undo breakage risk |
| banned | `orchestrat` (CLAUDE.md) | Banned word |
| 3.14 | "complete", "production-ready", "fully" in code comments | Aspirational doc |

## Phase 2 — Semantic Subsystem Reviews (serial)

Ordered by risk. Each produces `AUDIT/subsystem_XX.md` with rule → finding → file:line → proposed fix → severity.

1. **command_manager + commands/** — 2.29, 2.33, 2.21, 1.9, 2.5. Every command has `sequence_id`; executors persist derived values; no menu-resolved params.
2. **playback_controller + display engine** — 3.0 (MVC pull in park mode), 4.2 (engine owns boundaries). Boundary math must live in engine, not players.
3. **timeline_state + models/** — 1.14 (asserts on required IDs), 2.21 (impossible-states), unit discipline (timeline vs source frames).
4. **qt_bindings/ vs ui/** — 1.10, 2.18. No business logic in bindings; no direct Qt in `ui/` Lua.
5. **importers/ (DRP, prproj)** — 1.12 (external input must not crash; validate + warn). Different posture from internal-state assertions.
6. **core/signals + watchers + persistence** — 3.0 (emit on change), 2.30 (track heights persistence), no silent DB writes.
7. **media/ + media_cache + readers** — malloc-in-hot-loop check, unified A/V paths, no boundary math.
8. **schema.sql + migrations** — 3.1 (no legacy shims), 2.15 (no backcompat).

## Phase 3 — Test-Suite Audit

Rules 2.20, 2.31, 2.32, 2.34. Separate pass on `tests/`.

- Sample 20 tests randomly; judge: **domain behavior** or **implementation** (2.34)?
- Flag tests whose expected values were clearly derived by tracing code.
- Grep for mocks that encode data assumptions.
- Find commands / branches with no corresponding test (2.32).

## Phase 4 — Synthesis

- Roll `AUDIT/rule_*.md` + `AUDIT/subsystem_*.md` into ranked `AUDIT/findings.md`.
- Group: **must-fix now** (P0/P1), **backlog** (P2/P3), **needs Joe decision** (scope/architectural calls).
- No auto-fixing in this pass. Fixes land in follow-up commits, one rule or subsystem per commit.
- Remediation clusters that need real design (e.g., "rewrite implementation-coupled tests") are candidates for a full `/specify` pass later.

## Deliverables

- `AUDIT/findings.md` — prioritized ledger
- `AUDIT/rule_XX.md` — raw hits per static rule
- `AUDIT/subsystem_XX.md` — semantic review per subsystem
- Recommendation list of follow-up branches, one per cluster

## Unresolved questions

- output to `AUDIT/` dir or single md report?
- `tests/` in scope, or separate pass later?
- fix inline as found, or review-only then separate fix commits?
- `orchestrat` + marketing-word purge blocking or P2 backlog?
- vendored files — skip entirely or include?
- scope: whole repo, or `src/lua/` first?
- time budget: one session, a few days, open-ended?
