# Quickstart: Resolve Color Roundtrip — acceptance walkthrough

Validates the seven acceptance scenarios (spec.md) against a **real Resolve Studio** on the same machine. This is the smoke walkthrough; it is the source for the live tests under `tests/live/`. Each step asserts an **observable fact**, not "the call returned."

**Preconditions**: Resolve Studio running; a JVE project open with a graded-candidate sequence whose media exists on a local path; the helper built (Lua or Python per the Phase-0 spike).

---

## 0. Helper is alive
- JVE (or the runner) spawns the helper and `ping`s.
- **Assert**: `ok:true`, `resolve_connected:true`, a real `resolve_version` string. Log the version.

## 1. Send the cut (FR-001, 002, 007 — Scenario 1)
- Run command `SendToResolve` on a sequence of N clips. It authors a `.drt`, round-trips it through JVE's own importer (must read back as intended), then calls `import_timeline`.
- **Assert**: the Resolve timeline contains **N items**; for a chosen item K, the recovered join key **byte-equals** the JVE clip id JVE wrote; any unrelinkable media appears in `unrelinked` (and the user is told), never silently missing.

## 2. Grade a primary CDL, sync back, display (FR-014, 015, 016 — Scenario 2)
- In Resolve, apply a known primary grade to one clip (e.g. slope `(1.05,0.98,0.92)`, offset `(0.01,0,-0.02)`, power `(1.1,1.0,0.95)`, sat `0.85`).
- Run `SyncGradesFromResolve`.
- **Assert**: `clip_grade` for that clip stores the CDL with `fidelity='primary'`; the JVE viewer shows the graded result; a JVE render of that frame **pixel-matches** Resolve's render of the same frame within tolerance. (Tolerance set in the Phase-3 pixel test.)

## 3. Grade a complex node graph, sync, fidelity honesty (FR-015 — Scenario 3)
- In Resolve, add a power window / secondary (exceeds CDL) to another clip. Sync.
- **Assert**: that clip's `fidelity` is `partial` or `unrepresentable`; JVE does **not** claim to reproduce the full look (UX shows the "full grade requires Resolve render" affordance).

## 4. Undo the sync (FR-017 — Scenario 4)
- Undo after step 2/3.
- **Assert**: prior grade state restored (the clip that had no grade has none again; a previously-graded clip reverts to its earlier values).

## 5. Blade + re-send, grades inherit (FR-012 — Scenario 5)
- Blade a graded clip into two in JVE; run `SendToResolve` again.
- **Assert**: both halves carry the parent's grade (inherited); no other clip's grade is scrambled.

## 6. Idempotency (FR-008 — Scenario 6)
- Re-send `import_timeline` bearing the **same `change_token`** (simulate a dropped reply; `id` may be fresh).
- **Assert**: Resolve timeline item count unchanged (state changed exactly once); the second response equals the first.

## 7. Render + relink (FR-018, 019 — Scenario 7)
- Run `QueueResolveRender`; poll `render_status` to completion.
- **Assert**: the output file exists at `output_paths`; JVE relinks the affected clips to the rendered masters (existing relink path) and plays the graded footage.

---

## Edge / failure checks (spec Edge Cases)
- **Free Resolve**: against a non-Studio Resolve, `ping`/`import_timeline` returns `not_studio`; JVE surfaces it and does nothing destructive.
- **Stale handle**: switch project in Resolve's UI mid-session, then run a verb → `handle_stale` reported (or transparent reacquire), never silent wrong-project writes.
- **Locale rate**: with a non-US locale decimal setting, a 23.976 source must not read back as 23 — `locale_rate_corruption` raised, conform refused.
- **Deleted graded clip**: delete a graded clip in JVE → its `clip_grade` + `resolve_bridge_link` rows are gone (cascade).
- **Resolve item removed**: remove an item in Resolve, sync → that JVE clip's grade is retained but marked `stale`.

## Definition of green
All seven scenarios pass as observable facts, the edge checks behave as specified, `ping` reports `resolve_version`, and the locale guard is exercised. No test passes by its own setup.
