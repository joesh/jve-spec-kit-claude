<!--
Sync Impact Report:
Version change: 1.0.0 → 2.0.0
Modified principles: Rewrote all principles to match CLAUDE.md and ENGINEERING.md
Added sections: Fail-Fast, No Fallbacks, No Backward Compat, MVC, Functions-as-Algorithms
Removed sections: CLI Interface Standard (not applicable to desktop GUI app)
Templates requiring updates: plan-template.md constitution check section
Follow-up TODOs: Update plan template constitution check to match new principles
-->

# JVE Spec Kit for Claude Constitution

## Core Principles

### I. Modular Architecture
Every feature starts as a standalone module with clear boundaries. Modules MUST be self-contained, independently testable, and solve a specific problem. Core logic (pure functions, no UI dependencies) is separated from UI and command layers. MVC is mandatory: views pull from model state, never depend on imperative push.

Rationale: Modularity ensures testability. MVC ensures views always know what to display by querying the model.

### II. Command-Driven Interface
All user-facing operations MUST be registered commands in the command_manager system. Commands are accessible via menu items, keyboard shortcuts, and programmatic execution. Undoable commands capture state for undo/redo. This is the desktop GUI equivalent of a CLI interface.

Rationale: Consistent command dispatch enables keyboard shortcuts, menu items, scripting, and undo/redo through a single mechanism.

### III. Test-First Development (NON-NEGOTIABLE)
TDD is mandatory. Tests MUST be written first, verified to fail, then implementation makes them pass. When fixing a bug: write a regression test that fails FIRST, verify the failure, only then implement the fix. Tests must be black-box — test outputs and side effects, not internals. Zero mocks that encode assumptions. Non-trivial values only.

Rationale: TDD prevents regression and validates requirements. Black-box tests catch real bugs; mock-heavy tests give false confidence.

### IV. Documentation-Driven Specifications
All features begin with specifications before implementation. Specs MUST include user scenarios, functional requirements, and acceptance criteria. Implementation follows specification, not the reverse.

Rationale: Clear specifications prevent scope creep and provide measurable success criteria.

### V. Template-Based Consistency
All project artifacts MUST follow established templates for specifications, plans, tasks, and documentation. Templates ensure consistency and enable automated validation.

Rationale: Standardized formats reduce errors and enable tooling automation.

### VI. Fail-Fast Assert Policy
This codebase is in active development. Prefer immediate hard failure over recovery. If a state should never be possible, it MUST crash loudly with an assert that includes the function/module name and relevant IDs. No silent fallbacks. No invented defaults. No "print and continue" for invariants. DB is internal state — missing rows are bugs, not recovery opportunities.

Rationale: Silent failures hide bugs. Asserts surface them immediately with actionable context.

### VII. No Fallbacks or Default Values
NEVER use fallback values — they hide errors. NEVER assume defaults — get actual values or assert. Surface all errors immediately. No `or 0`, no `or ""`, no `or "default"` on required data.

Rationale: Fallbacks mask the root cause. Explicit failure forces the real fix.

### VIII. No Backward Compatibility
DO NOT maintain backward compatibility for schemas, APIs, data stores, or workflows. Delete legacy paths as soon as replacements exist. Never add shims, migrations, or old-code preservation unless Joe explicitly asks. Old projects get deleted/reset, not migrated.

Rationale: Backward compat accretes complexity. In active development, clean breaks are cheaper than migration code.

## Quality Standards

All code MUST pass luacheck (zero warnings) and all tests via `make -j4`. Performance requirements are domain-specific and MUST be defined upfront. Tests must use non-trivial values that exercise real edge cases — boundary conditions, unit conversion, coordinate spaces.

Error handling: fail-fast with asserts in development. Use the logger module (never bare `print` except in tests). No "graceful degradation", retries, or compatibility shims unless Joe explicitly asks.

Functions MUST read like high-level algorithms calling subfunctions. Never mix high-level logic with low-level implementation details. Short functions, logical file splitting.

## Development Workflow

All changes MUST follow the specification → plan → tasks → implementation → validation workflow. No implementation may begin without a specification and plan.

Before modifying any subsystem: read 2+ working examples of the same pattern, trace the full execution path. Use the SAME mechanisms as existing code. Never guess from function names — read the code.

Before starting any refactor: run `git status` and warn if there are uncommitted changes. Refactors start from a clean tree.

## Governance

This constitution reflects the engineering standards in CLAUDE.md and ENGINEERING.md. Conflicts between this constitution and those files MUST be resolved by updating this constitution to match — CLAUDE.md and ENGINEERING.md are authoritative.

No backward compatibility requirements for constitutional changes. When principles change, update directly.

**Version**: 2.0.0 | **Ratified**: 2025-09-26 | **Last Amended**: 2026-03-26
