# 015 Refactor Plan — TimelineTab abstraction + shape-keyed Patches

**Goal**: replace `timeline_state.M.state` flat singleton with a TimelineTab object owned by a TimelineTabStrip. Adopt shape-keyed Patches per spec.md F2. Land all earlier-review bugs as side effects of the refactor (most collapse once the abstraction exists).

**Scope**: stays on branch `015-source-in-timeline`. Forward-only schema (rule 2.15) — no migration of existing per-clip patches.enabled state since 015 isn't released. Spec docs (data-model.md, plan.md, research.md, quickstart.md, tasks.md, contracts/) are stale and will be deleted at the end since the rewritten `spec.md` supersedes them.

## Approach

**Facade-first**, not big-bang. Keep `timeline_state.lua`'s public API stable; internally delegate to TimelineTabStrip. Each consumer migrates incrementally. Tests stay green at every commit.

## Phases

### Phase 1 — Build the abstraction (no consumer changes) ✅ DONE
Create two new modules. No existing file changes. Tests added for new modules in isolation.

- `src/lua/ui/timeline/timeline_tab.lua` — **thin handle**: `(id, kind, sequence_id)` + listener pub/sub. **No per-tab display state** — viewport/playhead/marks/scroll live on the sequence row; tab getters pull lazily. Methods: `get_marks()`, `reload(new_sequence_id)`, `add_listener/remove_listener`, `serialize/deserialize`. (Selection and drag are global on timeline_state, not per-tab.)
- `src/lua/ui/timeline/timeline_tab_strip.lua` — holder. Fields: `tabs[]`, `displayed_tab`, `active_record_tab`, `source_tab`. Methods: `open_record_tab`, `close_record_tab`, `open_source_tab` (singleton; reloads in place), `close_source_tab`, `switch_displayed` (FR-005), `switch_active_record` (FR-004), `serialize/deserialize`. SourceTab is always first.
- Tests: 21 sub-tests across `test_timeline_tab.lua` (8) and `test_timeline_tab_strip.lua` (13). Cover happy + error paths, identity preservation across reload, pointer recovery on close, deserialize assertions.

**Commit boundary reached.** New abstraction in place; zero existing consumers touched; sampled existing 015 tests still pass; luacheck 0 warnings.

### Phase 2 — Encapsulate existing tab state into the strip
**Split into 4 sub-commits for safe incremental landing:**

- **2a ✅ (commit `da1d1ebd`)** — instantiate `tab_strip` in `timeline_state.lua`; expose via `M.get_tab_strip()`; reset on `project_changed`. 3 sub-tests in `test_timeline_state_tab_strip.lua`.
- **2b ✅ (commit `085b91ab`)** — mirror tab open/close from `timeline_panel.lua` into the strip. `ensure_tab_for_sequence` hoists `strip:open_*_tab` above the early-return so it runs on every call; `close_tab` mirrors via seq_id-equality guard (Option 3) to handle source-master transition (A→B singleton reload). Integration test deferred to Phase 9 (Qt-gated path).
- **2c-i ✅ (commit `9419765d`)** — sync strip active+displayed pointers on `switch_to_record_tab` / `switch_to_source_tab`. Adds `TimelineTabStrip:find_record_tab_by_sequence_id` (kind-aware lookup). 2 new sub-tests cover FR-004 + FR-005.
- **2c-ii ✅ (commit `73278d35`)** — fix display-aware mark bugs in `timeline_panel.lua` selection listener and `timeline_scrollbar.lua` overlay. Both were reading active marks instead of displayed marks; switched to `get_display_mark_in/out`. Integration test deferred to Phase 9.

**Original plan (preserved for reference):**

The current codebase **already has** record-tab state: `open_tabs` (Qt widget map) and `tab_order` (ordered list of sequence_ids) at module-scope in `timeline_panel.lua`, persisted as `open_sequence_ids` in `project_settings`. Per-tab display state (viewport, playhead, scroll, marks) lives on the **sequence row**, not on the tab. The job is to **encapsulate the existing state into the strip**, not invent parallel persistence.

- Replace `timeline_panel.lua`'s module-local `open_tabs`/`tab_order` with a single `TimelineTabStrip` instance owned by TimelineView. The Qt widget bookkeeping (button, container, handlers) stays in `timeline_panel.lua` keyed by `tab.id`, but the strip is the source of truth for ordering + open/closed + pointers.
- Persistence: continue using `project_settings.open_sequence_ids` (existing schema); extend the value to encode tab kind (record vs source) — e.g., switch from a list of `sequence_id` strings to a list of `{kind, sequence_id}` tuples. Or add a separate `source_tab_sequence_id` key. Decide at Phase 2 start; minor schema additions only.
- `timeline_state.lua` becomes a facade: `M.get_playhead_position`, `M.get_mark_in`, `M.set_viewport_duration` delegate to `M._tab_strip:get_displayed()`'s underlying sequence-row reads/writes (which already exist via Sequence model).
- `data.source_sequence` cache is removed; SourceTab IS the source-sequence reference. `marks_changed` listener becomes a no-op (marks pulled lazily from sequence row).
- `displayed_tab_id` and `sequence_id` (active) sibling fields are removed; replaced by tab-strip pointer methods.
- `source_tab_dismissed` module-level flag in `timeline_panel.lua` is removed; SourceTab open/closed is part of the persisted tab list per F1 (Joe's spec edit).
- The strip is reinitialized when TimelineView is reinitialized (on `project_changed`).

**Strategy**: enumerate all `timeline_state.*` call sites first, group by consumer module, migrate consumer-by-consumer with tests run between each. The facade preserves public API; corner cases are in chained accessors.

**Commit boundary**: `timeline_panel.lua` and `timeline_state.lua` refactored to use the strip; all other consumers untouched. Existing tests pass via facade.

### Phase 3 ✅ (commit `c567b7aa`) — strip-back the display-aware accessors

Smaller scope than originally planned: rewrote `get_display_mark_in/out` and `is_source_tab_displayed` to read off `tab_strip:get_displayed()` instead of dispatching via the `displayed_tab_id != sequence_id` heuristic. `TimelineTab:get_marks()` pulls fresh from the sequence row (MVC, rule 3.0). The flat-singleton dispatch helper is gone; the public accessor names stay (renaming touches too many callers and the Phase 2c-ii bug fixes already routed consumers correctly).

`get_mark_in/out` and `get_source_mark_in/out` continue to read cached `data.sequence` / `data.source_sequence` because `get_ghost_mark` reads frame_rate at 60Hz and per-call `Sequence.load` would mean a DB hit per frame. Phase 6 can add a cached frame_rate accessor to TimelineTab if the cache becomes a maintenance burden.

Test: integration sub-test in `test_timeline_state_tab_strip` verifies the source/record marks toggle correctly when displayed tab swaps (40 vs 120 to disambiguate).

### Phase 4 — Per-sequence-sticky patches + presets + shape-gating

**Model decided (2026-05-10 research)**: per-sequence-sticky matches Premiere's documented mainstream behavior. Shape-gating is a UI-layer filter (hide rows whose source channel doesn't exist on the current load), NOT a data-layer key. Source Patch Presets give explicit-recall workflows that supersede Avid's per-clip memory. Schema rewrite is forward-only (015 unreleased).

Independent of tab refactor; can run in parallel branch and merge. Recommend doing it after Phase 3 to avoid double-touching patch commands.

- Schema migration: drop existing 015 `patches` table, recreate with `(id, sequence_id, track_type, source_track_index, record_track_index, enabled, created_at, UNIQUE(sequence_id, track_type, source_track_index))`. Forward-only. `track_type` keeps V1 and A1 as independent patch rows (rule 2.21 — impossible states unrepresentable).
- Add `source_patch_presets` table per spec F2 schema.
- Add `tracks.autoselect INTEGER NOT NULL DEFAULT 1 CHECK(autoselect IN (0,1))` migration.
- Update `set_patch.lua`: lookup/upsert keyed by `(record_seq, track_type, source_track_index)`.
- Update `patches` model `find_*` accordingly.
- Update edit-time inclusion gate in `batch_ripple_edit.lua` and `insert.lua`: source channel included iff `(no patch row OR patch.enabled=1) AND record_track.autoselect=1`.
- Shape-gating logic in `timeline_panel.lua` track-header rendering: hide patch buttons for source-track-indices that don't exist on the currently-loaded source. Pure UI filter; never deletes `patches` rows.
- New non-undoable commands: `RestoreDefaultPatch` (deletes all `patches` WHERE `sequence_id=?`), `SaveSourcePatchPreset(name)`, `RecallSourcePatchPreset(name)`, `DeleteSourcePatchPreset(name)`.
- `patch_changed` signal contract: emit `(sequence_id, track_type, source_track_index, change_type)` — `track_type` IS load-bearing now (disambiguates V1 vs A1). Update `signals.md` to document the 4-arg shape (was undocumented in the prior 015 work).
- Tests: per-sequence-sticky persistence across source loads (acceptance 2a), shape-gated visibility (2b), Restore Default Patch scope (2c), preset save/recall/replace semantics (2d), default-row-absence behavior, autoselect AND-gate.

**Commit boundary**: schema + patches code consistent. Existing patch tests updated to new keying.

### Phase 5 — Auto-create record tracks bug fix
`batch_ripple_edit.lua:139-158` (`auto_create_record_audio_tracks`) blindly fills tracks up to source count. Fix per spec F2 + Joe's correction: fill 1..N up to the highest referenced `record_track_index` from enabled patches in the edit.

- Rewrite the function to compute `max_referenced_index = max(patch.record_track_index for enabled patches in edit)`, create missing tracks 1..max_referenced_index, in the same command.
- Move auto-create AFTER the empty-sequence short-circuit in `insert.lua` so no orphan tracks on no-op edits.
- Test: patch routes A1→A5 with no A4 present → A4 AND A5 created; no A6.
- 2026-05-28: id_pool helper introduced at `core/commands/_id_pool.lua`. Four uuid-generating sites inside Insert/Overwrite (clips, link group, auto-tracks, split right-halves) all route through pools seeded from the command's persisted `created_clip_ids` / `created_link_group_id` / `auto_track_ids` / `split_capture` / `occluded_capture`. Redo replays reuse the same uuids the original execute committed; before, every redo regenerated fresh ids and broke anything holding a reference. Surfaced by `test_undo_property` P3 row_field_drift cluster.
- 2026-05-28: FR-029b cleanup contract widened. Two auto-create sites had to thread through the same `auto_track_ids` persisted parameter so Insert/Overwrite undoers can `Track.delete` the full set: (1) `auto_create_record_audio_tracks` (patch-driven pre-check, Insert only) AND (2) `_place_shared.ensure_owner_track_at_idx` (video target + per-audio patch routing, Insert + Overwrite). Plan returns `created_owner_track_ids`; executors merge into the persisted list. Overwrite gained `auto_track_ids` in SPEC.persisted + Track.delete loop in its undoer (was previously leaking auto-tracks on undo entirely). Surfaced by `test_undo_property` P1 Insert track-count drift.

### Phase 6 — Hygiene cleanup
- Tighten asserts on `set_sync_mode.lua:23`, `toggle_track_preference.lua:24` to require `sequence_id` (rule 2.29).
- Replace `or {}` fallbacks at `batch_ripple_edit.lua:620, 661-664, 870-872` with asserts.
- Wrap `SplitClip` mutation + DB commit in a transaction or defer cache mutation until after commit.
- Fix `set_patch.lua:70` `change_type` bug (currently falls through to "updated" when enabled is nil).
- Drop palette code from `set_patch.lua:25-34` and `Patch.create` color column — palette is out-of-scope per spec.
- Fold `source_routing_view_pref.lua` and `source_routing_view_state.lua` into one module (one preference + one modifier toggle doesn't need two files).
- ~~Decide on `add_clip_to_track.lua`~~ — DELETED 2026-05-28: had zero non-test callers; relied on `undoable=false` + FK CASCADE as a backdoor for "track lifetime governs clip lifetime". Test rewritten against the Insert path the user actually walks.
- Delete dead drag code (commit 9e32b801 mentioned this; sweep again).

### Phase 7 — Decompose `timeline_panel.lua`
Optional — recommend a follow-up PR to keep this one digestible. ~3079 lines down to maybe ~1500 by extracting:
- `src/lua/ui/timeline/track_header_layout.lua` — cell layout, drag-target registry.
- `src/lua/ui/timeline/patch_button_renderer.lua` — src/rec id button rendering.
- `src/lua/ui/timeline/sync_mode_button.lua` — sync-mode cycle cell.
- `src/lua/ui/timeline/sm_stack.lua` — Solo/Mute vertical stack.

### Phase 8 — Spec doc cleanup
- Delete `specs/015-source-in-timeline/{data-model.md, plan.md, research.md, quickstart.md, tasks.md}` and `contracts/` — superseded by rewritten `spec.md`.
- Delete `design examples/source_in_timeline_v{1,2,3}.html` — keep v4.
- Update `signals.md` for new `patch_changed` shape OR delete it if not load-bearing.

### Phase 9 — Final audit + tests
- Run full `make -j4`. All Lua + C++ + integration tests green.
- Audit diff against ENGINEERING.md rules 1.14, 2.5, 2.13, 2.15, 2.20, 2.29, 2.32, 3.0 per memory. Report → fix.
- Add missing integration tests called out in original review:
  - Ghost-mark end-to-end (set src marks + rec in → switch tabs → verify ghost rec_out renders dashed/labeled).
  - SourceTab close+reopen restores patches/sync_mode.
  - Solo toggle on SourceTab-displayed track does not perturb active record sequence playback.
  - Tab switch is instant (no DB round-trip).

## Sequencing

Phases 1–3 are the spine and must happen in order. Phase 4 can run parallel to 3 (or after — recommend after). Phase 5 depends on Phase 4's autoselect column. Phase 6 can interleave with 4–5. Phase 7 is optional and recommended as follow-up. Phase 8 last. Phase 9 last.

**Suggested commit cadence**: one commit per phase, except Phase 6 which can be split per fix-group, and Phase 7 if attempted in this PR which should be one commit per extracted module.

## Risk + verification

| Phase | Risk | Verification |
|---|---|---|
| 1 | Tab object misses a needed field | New module tests + Phase 2 facade reveals gaps immediately |
| 2 | Facade leaks state, consumers break silently | Full test suite at commit |
| 3 | Wrong sequence_id passed to edit commands | Existing edit tests cover; add ghost-mark test for active vs displayed |
| 4 | Shape signature ambiguity | Test with stereo-pair vs 2-mono case explicitly |
| 5 | Auto-create gap-fill (track 5 with no track 4) bug returns | Test patch-to-A5-with-no-A4 case |
| 6 | Hygiene fixes regress something | Per-fix tests |
| 7 | Module extraction breaks Qt widget refs | Run UI smoke test (open project, click around) |

## Estimated effort

~16–20 hours focused (2–3 days). Phase 7 adds ~4–6 hours if done in this PR.

## Decisions (locked 2026-05-10)

1. Phase 7 (timeline_panel.lua decomposition): **follow-up PR**, not in this one.
2. Phase 4 schema migration: **bump schema version** per rule 3.1.
3. Phase 8 spec docs: **delete** `data-model.md`, `plan.md`, `research.md`, `quickstart.md`, `tasks.md`, `contracts/`.
4. Phase 8 design HTMLs: **delete** `source_in_timeline_v{1,2,3}.html` (keep v4).

## Audit pass 19d (2026-05-28)

Extended id_pool to Blade + ExtractRange (→ TrimHead).

- **Blade**: clip_pool (right-half clip ids) + link_group_pool (new right-half link
  groups). Sorted `right_halves_by_group` keys before pool consumption — `pairs()`
  iteration order is undefined and would have desynced redo.
- **ExtractRange**: single clip_pool feeds both lift and ripple phases. New helper
  `_id_pool.reid_inserts(actions, pool)` rewrites split-half ids on `clip_mutator`-
  planned actions BEFORE `apply_mutations`. Keeps clip_mutator API unchanged for
  the 7 other callers (Nudge, OverwriteTrimEdge, LiftRange, MoveClipToTrack,
  Paste, BatchRippleEdit). Pattern: command owns id stability; planner plans.
- **`clip_link.create_link_group(clips, db, forced_id)`** unchanged from 19c.

Harness (seed=42): 25 → 2. P3 redo idempotence 100% across all commands.
Remaining 2 P2 findings are random-history interactions (duration_frames drift +
clip row count) — separate investigation.

## Audit pass 19e (2026-05-28)

Cascade-deleted clip_link rows now restored on undo.

- **`clip_link.capture_for_clip(clip_id, db)` / `restore_rows(rows, db)`** —
  raw-row capture + replay helpers. Captures `(link_group_id, role,
  time_offset, enabled)`, drops autoincrement `id` (logical identity is the
  tuple, see test_undo_property's SORT_KEYS).
- **`_place_shared.occlude_full_cover(e)`** captures BEFORE `Clip.delete_by_ids`
  (FK ON DELETE CASCADE wipes them otherwise). Stashes `e.captured_links`.
- **Overwrite undoer** asserts `d.captured_links` is a table and calls
  `ClipLink.restore_rows` after `Clip.create`. Removes the "re-link is a
  future enhancement" comment.
- **`command_helper.apply_mutations` / `restore_deleted_clip_revert`** —
  same pattern at the generic mutation pipeline. Every `clip_mutator`
  delete (resolve_occlusions, resolve_ripple, etc.) captures its links
  pre-cascade; revert restores after re-INSERT. Covers MoveClipToTrack,
  ExtractRange (→ TrimHead/DeleteSelection/Cut with marks), LiftRange,
  Paste, OverwriteTrimEdge, BatchRippleEdit.
- **`Clip.find_overlapping_on_track` SELECT** added `master_audio_track_id` —
  was silently dropped, undo restored linked-stem clips with that column nil.
  Overwrite undoer passes it through.

Harness (seed=42, uuid pre-seeded for reproducibility): runs 38, 42, 45 cleared.
Two end-state findings remain at run=15 (MoveClipToTrack at undo #4) and run=30
(TrimHead at undo #5) — deeper cross-command interaction in cumulative
execute→undo of 10-command random histories. Separate investigation.
