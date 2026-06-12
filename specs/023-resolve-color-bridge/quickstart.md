# Quickstart: Resolve Color Roundtrip — acceptance walkthrough

Validates the seven acceptance scenarios (spec.md) against a **real Resolve Studio** on the same machine. This is the smoke walkthrough; it is the source for the live tests under `tests/live/`. Each step asserts an **observable fact**, not "the call returned."

**Preconditions**: Resolve Studio running; a JVE project open with a graded-candidate sequence whose media exists on a local path; the helper built (Lua or Python per the Phase-0 spike).

---

## 0. Helper is alive
- JVE (or the runner) spawns the helper and `ping`s.
- **Assert**: `ok:true`, `resolve_connected:true`, a real `resolve_version` string. Log the version.

## 1. Send the cut (FR-001, 002, 007 — Scenario 1, outbound)
- Run command `SendToResolve` on a sequence of N clips. It authors a `.drt`, round-trips it through JVE's own importer (must read back as intended), then calls `import_timeline`.
- **Assert**: the Resolve timeline contains **N items**; for a chosen item K, the recovered join key **byte-equals** the JVE clip id JVE wrote; any unrelinkable media appears in `unrelinked` (and the user is told), never silently missing.

## 1b. Connect an imported graded project (FR-011b/c — inbound, the "I imported a graded DRP" flow)
- Start from a JVE project that was **imported from a graded DRP** (so `clip.id` = the Resolve timeline-item id, FR-011b), with the same project open live in Resolve.
- Run `ConnectToResolveProject`.
- **Assert**: every clip with an adopted id links directly to its live timeline item (`jve_guid == resolve_item_id`); clips without an adopted id (e.g. blades made after import) match positionally; the unmatched count is reported, not silently zero. Then `SyncGradesFromResolve` and **assert grades land on the right clips** — this is the answer to "hook the imported DRP's grade up to the jvp."

## 2. Grade a primary CDL, sync back, display (FR-014, 015, 016 — Scenario 2)
- In Resolve, apply a known primary grade to one clip (e.g. slope `(1.05,0.98,0.92)`, offset `(0.01,0,-0.02)`, power `(1.1,1.0,0.95)`, sat `0.85`).
- Run `SyncGradesFromResolve`.
- **Assert**: `clip_grade` for that clip stores the CDL with `fidelity='primary'`; the JVE viewer shows the graded result; a JVE render of that frame **pixel-matches** Resolve's render of the same frame within tolerance. (Tolerance set in the Phase-3 pixel test.)

## 3. Grade a complex node graph, sync, fidelity honesty (FR-015 — Scenario 3)
- In Resolve, add a power window / secondary (exceeds CDL) to another clip. Sync.
- **Assert**: that clip's `fidelity` is `partial` or `unrepresentable`; JVE does **not** claim to reproduce the full look (UX shows the fidelity badge).

## 4. Undo the sync (FR-017 — Scenario 4)
- Undo after step 2/3.
- **Assert**: prior grade state restored (the clip that had no grade has none again; a previously-graded clip reverts to its earlier values).

## 5. Blade + re-send, grades inherit (FR-012 — Scenario 5)
- Blade a graded clip into two in JVE; run `SendToResolve` again.
- **Assert**: both halves carry the parent's grade (inherited); no other clip's grade is scrambled.

## 6. Idempotency (FR-008 — Scenario 6)
- Re-send `import_timeline` bearing the **same `change_token`** (simulate a dropped reply; `id` may be fresh).
- **Assert**: Resolve timeline item count unchanged (state changed exactly once); the second response equals the first.

## 7. ~~Render + relink~~ — CARVED OUT 2026-06-02
Former scenario covering `QueueResolveRender` + auto-relink. Preserved at git tag `spec023-render-relink-deferred`. See `feedback_render_relink_carved_out` for the rationale.

## 8. Pull Resolve-side edit tweaks (FR-024/025)
- In Resolve, trim/slip/move a connected clip; run `SyncEditsFromResolve`.
- **Assert**: the matched JVE clip's record/source/track/enabled update to the Resolve values (undoable in one step).
- Then locally edit a different JVE clip, change the same clip in Resolve too, and pull again.
- **Assert**: the locally-edited clip surfaces as a **conflict** (keep JVE / take Resolve), never silently overwritten; non-conflicting clips apply directly.

---

## Edge / failure checks (spec Edge Cases)
- **Free Resolve**: against a non-Studio Resolve, `ping`/`import_timeline` returns `not_studio`; JVE surfaces it and does nothing destructive.
- **Stale handle**: switch project in Resolve's UI mid-session, then run a verb → `handle_stale` reported (or transparent reacquire), never silent wrong-project writes.
- **Locale rate**: with a non-US locale decimal setting, a 23.976 source must not read back as 23 — `locale_rate_corruption` raised, conform refused.
- **Deleted graded clip**: delete a graded clip in JVE → its `clip_grade` + `resolve_bridge_link` rows are gone (cascade).
- **Resolve item removed**: remove an item in Resolve, sync → that JVE clip's grade is retained but marked `stale`.

## Observed results (T045 walkthrough — recorded 2026-06-12, VM Resolve Studio 20.3)

Every automatable scenario passes as an observable fact via the committed live suite (each test asserts model/timeline state, never "the call returned"):

| Step | Evidence | Status |
|---|---|---|
| 0 ping + version | every live test's `skip_unless_live` gate logs `resolve_version` (e.g. T026 run) | ✅ live |
| 1 send, N items, byte-equal identity | T026 (2 mapped + relinked), T037 (identities intact across re-send), T055/T033 (mapping consumed downstream) | ✅ live |
| 1b connect imported + grades land right | T050 — 3/3 position-matched, e1 markers correctly ignored, SyncGrades lands each CDL on the right e2 clip | ✅ live |
| 2 primary CDL sync + display + pixel-match | T037 (values round-trip), T033 (`jve_apply_cdl(resolve_ungraded) ≈ resolve_graded`, mean 0.31/255 max 1.07/255 / 8262 samples), viewer pull: `test_view_grade_pull` + `test_piece3_lut3d_surface_pull` | ✅ live |
| 3 fidelity honesty | T034 live (CDL→primary, LUT→partial, untouched→none; identity-CDL filter); badge + §5.5 affordance: `test_inspectable_fidelity_affordance`. **Power-window leg manual** — no scripting write surface (T034 note) | ✅ live (one manual leg ⚠) |
| 4 undo the sync | `test_sync_grades_command` black-box undo round-trip (offline; same command path the live flow uses) | ✅ offline |
| 5 blade + re-send inherit | T037 live (both halves carry parent grade, bystander untouched, fresh timeline uid) | ✅ live |
| 6 idempotency | T026 live (same token ⇒ deep-identical response incl. timeline uid; population unchanged) | ✅ live |
| 8 edit pull + conflict | T055 live (B applied via ToggleClipEnabled+OverwriteTrimEdge×2+Nudge; C conflict keeps local; D local-only kept) | ✅ live |
| Edge: free Resolve ⇒ not_studio | `test_resolve_handle_gates.py` (real product strings at the fusionscript boundary). **No free Resolve install exists to exercise live** | ✅ unit (live impossible ⚠) |
| Edge: stale handle on project switch | T042 live (probe switches project → `handle_stale` → recovery) | ✅ live |
| Edge: locale rate corruption | `test_cdl_edl.py` + `test_verbs.py` (truncation signatures 23/29/47/59 → `locale_rate_corruption`, conform refused). **Real non-US-locale Resolve not exercised** (would require relocaling the VM) | ✅ unit (live manual ⚠) |
| Edge: deleted graded clip cascade | `test_resolve_bridge_link_schema` (FK CASCADE) | ✅ offline |
| Edge: Resolve item removed ⇒ stale | `test_clip_grade_model` + FR-013a stale walk in `sync_grades_from_resolve` | ✅ offline |

Three legs cannot be automated and remain operator steps: power-window ⇒ `unrepresentable` (no scripting write surface), a genuinely free (non-Studio) Resolve, and a real non-US-locale Resolve. Unit coverage pins each contract; the live behaviors await a manual pass.

## Definition of green
All seven scenarios pass as observable facts, the edge checks behave as specified, `ping` reports `resolve_version`, and the locale guard is exercised. No test passes by its own setup.
