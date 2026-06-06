# JVE Editor

JVE is a hackable, script-forward video editor implemented primarily in Lua, with a thin host/UI layer.

This repository is organized so that *implementation-derived* knowledge is explicit and discoverable, rather than requiring repeated full-code walks.

### Baseline lock

The implementation review baseline under:

`docs/implementation-review-baseline/`

is **locked** and treated as authoritative documentation of the system as actually implemented.
It is not regenerated casually.

Subsequent changes are handled via incremental deltas under:

`docs/implementation-review-deltas/`

## Documentation map (read this first)

Authoritative documentation is split into:

### Implementation review baseline (full, implementation-derived)

`docs/implementation-review-baseline/` contains the ordered baseline derived from direct evaluation of the codebase:

- `01-REPO-OVERVIEW.md`
- `02-ARCHITECTURE-MAP.md`
- `03-CORE-INVARIANTS.md`
- `04-BEHAVIORAL-FLOWS.md`
- `05-STRUCTURAL-DEBT.md`
- `06-TEST-GAPS.md`
- `07-RISK-REGISTER.md`

### Implementation review deltas (incremental, change-scoped)

`docs/implementation-review-deltas/` contains:
- `REVIEW_CACHE.md` — rolling quick context (keep short; bullets; prune)
- dated delta notes: `YYYY-MM-DD-<topic>.md`

## Repository layout (high level)

- `src/` — runtime source code (authoritative)
- `tests/` — unit, integration, capture-based, and ad-hoc tests
- `docs/` — long-lived documentation (baseline + deltas)

Notes:
- This README is intentionally minimal and stable.
- Status claims must follow ENGINEERING.md §2.24 (evidence-based claims).
