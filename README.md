# JVE Editor

JVE is a hackable, script-forward video editor implemented primarily in Lua, with a thin host/UI layer.

This repository is organized so that architectural and operational knowledge is explicit and discoverable, rather than requiring repeated full-code walks.

## Documentation map (read this first)

The canonical documentation lives under `docs/`. These files are intentionally structured to be LLM- and human-navigable.

- **Codebase overview** → `docs/CODEBASE_OVERVIEW.md`
- **Architecture map** → `docs/ARCHITECTURE_MAP.md`
- **Golden paths** → `docs/GOLDEN_PATHS.md`
- **Invariants** → `docs/INVARIANTS.md`
- **Traps** → `docs/TRAPS.md`
- **Patterns** → `docs/PATTERNS.md`
- **Evidence index** → `docs/EVIDENCE_INDEX.md`
- **Review cache** → `docs/REVIEW_CACHE.md`

## Repository layout (high level)

- `src/` — runtime source code (authoritative)
- `tests/` — unit, integration, capture-based, and ad-hoc tests
- `docs/` — canonical, long-lived documentation

Notes:
- This README is intentionally minimal and stable.
- Status claims must follow ENGINEERING.md §2.24 (evidence-based claims).
