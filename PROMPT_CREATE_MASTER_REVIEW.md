You are reviewing this codebase to produce long-lived repo documentation that prevents repeated full-code walks.
Current top-level dirs: tests/ docs/ src/
Tests layout: tests/captures/ tests/unit/ tests/integration/ tests/ad_hoc/ tests/helpers/
Source layout: src/lua/ (ui/ qt_bindings/ inspectable/ core/ importers/ models/ bug_reporter/ media/) and src/bug_reporter/.

Deliverables (create/update files under docs/):

EVIDENCE_INDEX.md

CODEBASE_OVERVIEW.md

ARCHITECTURE_MAP.md

GOLDEN_PATHS.md

INVARIANTS.md

TRAPS.md

PATTERNS.md

Hard rules:

Every non-trivial claim must cite concrete evidence: file paths + (when possible) symbols/functions + a brief “why this file matters”.

Separate observed from inferred. Inferred statements must state the evidence that suggests them.

INVARIANTS.md: each invariant must include “How to verify” using tests/unit, tests/integration, captures, or a minimal repro.

GOLDEN_PATHS.md: include exact commands and expected success signals. If you cannot run a command, mark it UNVERIFIED and say what blocked it.

TRAPS.md: each trap needs Symptoms, Root cause (file/symbol anchors), Avoidance, and Detection (tests/log cues).

Keep CODEBASE_OVERVIEW.md short (1–2 pages). Push detail into the other docs.

Use stable, searchable headings and cross-links between docs.

Process (must follow in order):

Inventory pass: write docs/EVIDENCE_INDEX.md first. Include:

Entry points (what executable/scripts/tests start the system)

Key modules in src/lua/* and how they relate

Test map: what each test tier covers, how captures are used, and helpers

“Read first” list of 5–15 file paths (highest leverage)

Architecture pass: write docs/ARCHITECTURE_MAP.md with module boundaries + dataflow, including:

src/lua/ui and src/lua/qt_bindings bridge points

inspectable and models interaction patterns

persistence/state (likely in src/lua/core and models, validate via tests)

bug reporting: src/lua/bug_reporter + src/bug_reporter

Operational pass: write docs/GOLDEN_PATHS.md for:

running unit tests

running integration tests

using captures (record/replay/compare if applicable)

any ad_hoc workflows

Correctness pass: write docs/INVARIANTS.md grounded in tests and core logic.

Risk pass: write docs/TRAPS.md.

Style pass: write docs/PATTERNS.md (Lua module conventions, UI binding idioms, inspectable/model patterns, importers/media flow, bug reporter flow).

Final pass: cross-link docs, ensure no orphan concepts, ensure each section has evidence anchors.

Output requirements:

Use headings that are easy to search for: “Entry Points”, “Test Taxonomy”, “Module Boundaries”, “Data Flow”, “Lua-Qt Bridge”, “Models”, “Inspectable”, “Importers”, “Media”, “Bug Reporter”.

For each major module, include a “Primary files” list with 3–10 anchors.
