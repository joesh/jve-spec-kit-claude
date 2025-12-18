# Development Process (Agent Workflow)

This is the process I will follow for all future work in this repo. The goal is to prevent “review says X, PR does Y” drift by making scope, contracts, and verification explicit and mandatory.

## 1) Scope + Contract (written first)
- Define the 1-sentence goal (what changes, what does not).
- List any API/behavior contract changes (e.g. “`CommandManager.init` now requires non-empty `sequence_id`/`project_id`”).
- List explicit non-goals (what this PR will not attempt to fix).

## 2) Invariants (must hold)
- No untracked runtime dependencies: `git status` must not show `??` files required by code.
- Command executors/undoers do not manage transactions (no nested transaction hacks; if isolation is required, use an explicit, documented mechanism).
- Executor return contract is consistent end-to-end (failure cannot be treated as truthy success).
- Fail-fast via `assert()` is expected in development (see **ENGINEERING.md 1.14**). Do not replace invariants with “print and continue”, graceful degradation, or silent fallbacks.
- Assert messages must be actionable (function/module + relevant IDs/inputs).
- Test integrity is sacred (see **ENGINEERING.md 2.20** and **2.31**):
  - Do not touch tests as the first move. Attempt to fix the implementation first.
  - Do not “make tests pass” by weakening, inverting, skipping, or loosening existing assertions.
  - Do not change expected values/semantics without Joe’s explicit approval.
- Tests are the arbiter: do not claim “fixed” without passing tests.
- New codepaths require tests: when adding behavior, commands, handlers, or branches, add tests that exercise and verify the new paths (not just happy paths; include failure/edge cases).
  - If the “failure path” is an `assert()`, test it with `pcall()` and validate the error message contains the relevant IDs/inputs (actionable crash).

## 3) Preflight Gate (before coding)
- Review `git diff master --name-only` to understand blast radius.
- Search for “danger patterns” relevant to the change (examples: `default_*` fallbacks, `begin_transaction`, UI `assert(`).
- If this is a systematic sweep across many files, follow **ENGINEERING.md 2.19** (finish the sweep first); otherwise run the smallest targeted test(s) that cover the area being changed.

## 4) Implementation Loop (tight)
- Make one coherent change at a time (avoid mixed refactors + behavior changes).
- If a contract changes, update all callsites and relevant tests in the same change set.
- After each iteration, run targeted tests; if red, stop and fix immediately.
  - For new codepaths, add tests alongside the change and ensure both success and failure/edge paths are covered.
  - If you add an invariant `assert()`, ensure the assert message is specific enough that a failing test can prove it’s actionable.

## 5) Pre-merge Gate (mandatory)
- Run `./scripts/run_lua_tests.sh` and require a clean pass.
- Require a clean working tree (`git status` clean; no accidental debug edits; no untracked required files).
- Review any edits under `tests/` and explicitly justify them; modifying existing expectations/semantics requires Joe’s explicit approval (ENGINEERING.md 2.31).
- Review `git diff master` for:
  - unintended behavior changes,
  - formatting-only churn,
  - silent fallbacks / “print and continue” on invariants,
  - obvious performance footguns (e.g. N+1 DB queries).

## 6) Review Output (honesty rule)
- Do not say “fixed” unless I can point to:
  - a passing test (or new regression test), and/or
  - a reproduction that fails before and passes after.
