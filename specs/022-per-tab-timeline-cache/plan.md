# Per-tab timeline cache — Phase 1 of TabView refactor

**Status**: scheduled for autonomous execution 2026-05-26 23:00 PDT.
**Context window**: this doc + the repo state at fire time. No prior conversation.

## Long-term target (NOT what you're doing tonight — context only)

The eventual architecture (multi-week, separate effort):

```
App
├── PanelManager
│   └── panels: [ Panel, Panel, ... ]          -- all same class
└── InteractionState  (drag, focus)

Panel  (undifferentiated tab container)
├── tabs: [ TabView, ... ]
├── displayed_tab, active_tab
├── name = active_tab:get_title()              -- derived
└── tab_strip_widget                            -- pure presentation

TabView  (abstract base — interface + listener plumbing)
├── id, kind, title
└── (subclass-specific state below)

  SequenceView extends TabView
  ├── sequence_id, clips, tracks, viewport, playhead, selection
  ├── last_pointer_frame
  └── tracks_views: { video, audio }            -- the Lua coordinators wrapping
                                                  the C++ tracks-drawing widgets
                                                  (today's misnamed timeline_view.lua)

  InspectorView extends TabView
  BrowserView   extends TabView
  ...
```

Tonight's slice is **Phase 1**: lift the per-tab data cache onto the existing `TimelineTab` object. This sets up the eventual `SequenceView` (which is just the renamed + extended `TimelineTab` with subclass plumbing added).

**Do NOT in tonight's slice:**
- Rename anything (`TimelineTab` stays `TimelineTab`; `timeline_view.lua` stays as-is).
- Introduce `SequenceView` / `TabView` / `Panel` types.
- Touch `TimelineTabStrip`'s public surface (it's still the tab container).
- Touch `timeline_panel.lua` structurally.

Those are Phase 2+ work on a future session. Tonight's lift makes them mechanical when they happen.

## What you ARE doing tonight

Move the per-sequence data cache (clips, tracks, viewport, playhead, selection) **off** the singleton `timeline_state` global **onto** each `TimelineTab` instance. Lookups become tab methods (`tab:get_clips()` etc.). Callers obtain a tab from the strip (`strip:get_active_tab()` or `strip:get_displayed_tab()`) — no seq_id-keyed facade, no global-singleton-style shared reader.

## Why

`timeline_state` today holds:
- `data.state.sequence_id` — the **ACTIVE** (record) sequence_id
- `data.state.clips`, `data.state.tracks` — clips/tracks of the **DISPLAYED** sequence

When `displayed == active` (common case) they agree. When the user opens the source tab (e.g., via `source_viewer.load_clip` → `source_loaded_changed` listener at `timeline_panel.lua:1789` → `switch_to_source_tab`), `data.state.clips` gets replaced with the source master's clips while `data.state.sequence_id` still returns the record id. Commands targeting active (BRE, etc.) read a cache that doesn't contain their clips → silent no-op.

The smoke test `tests/smoke/cases/test_source_viewer_marks_track_live_clip_mutations.py` catches this (currently has a `switch_to_record_tab` workaround landed in the same session as this plan). The NSF defense landed in BRE (`src/lua/core/commands/batch_ripple_edit.lua`) errors loudly when the bug repeats. Tonight's refactor makes the bug impossible by construction: each tab carries its own cache, so BRE targeting active gets active's cache regardless of what's displayed.

## What "done" looks like

1. `TimelineTab` instances hold their own clip/track/viewport/playhead/selection cache. Open tab → load cache from DB. Close tab → cache goes with the GC.
2. `timeline_state.get_clips()` / `get_all_tracks()` / `get_track_clip_index(track_id)` / `get_sequence_id()` are **gone**. Replaced by `tab:get_clips()` / `tab:get_all_tracks()` / `tab:get_track_clip_index(track_id)` etc. on the `TimelineTab` instance. Callers obtain a tab via the strip:
   ```lua
   local strip = require("ui.timeline.state.strip_holder").get()
   local clips = strip:get_active_tab():get_clips()      -- commands
   local clips = strip:get_displayed_tab():get_clips()   -- view code
   ```
   No `seq_id`-parameterized facade. The intent ("active vs displayed") is encoded in which tab you ask for; the tab encapsulates its own data. This is non-negotiable for Phase 1 — picked because the alternative (seq_id-keyed facade) preserves the same global-singleton smell that caused the bug.
3. Tab switch becomes a pointer swap on the strip, NOT a cache rebuild. Verify by timing a switch between two record tabs each with ~3000 clips. Should be sub-millisecond.
4. The smoke test `test_in_edge_ripple_updates_source_viewer_effective_in` passes WITHOUT the `switch_to_record_tab` workaround currently in it. Remove that workaround.
5. The BRE NSF defense (cache-desync assert) you'll find in `build_clip_cache` stays — it now catches "no open tab for seq_id" as the bug surface, which is a clean error message.
6. Full smoke suite green: `python3 -m unittest discover tests/smoke/cases -v` (host).
7. Full `make -j4` clean (luacheck + Lua + C++ + binding + integration).

## What to NOT do

- **Do not** rename anything (see Phase 1 vs long-term split above).
- **Do not** add a DB fallback in tab lookups. Cache miss for an open tab → reload via the existing `load_displayed_sequence` path. Cache miss for an UNKNOWN seq_id (no open tab) → error loudly. Do not silently load from DB on arbitrary seq_ids.
- **Do not** change BRE, OpenProject, source_viewer, or any other command's signature/behavior. Stay inside `timeline_state` + `TimelineTab` + `TimelineTabStrip` + the lookup callsites.
- **Do not** introduce a watchers/observers system to replace signals (see `memory/project_signals_vs_watchers.md`).
- **Do not** push to a remote.
- **Do not** use repo-wide destructive git commands. Joe runs parallel Claude sessions; untracked files = sibling work. `git status` first; scope every operation to your own files.

## How to attack it

### Phase 1.1 — Internal restructure (no public-API change)
- Add `tab.cache` namespace on `TimelineTab` carrying the per-sequence fields that `data.state` holds today: `tracks`, `clips` (media + derived gaps), `content_length`, `sequence_frame_rate`, `sequence_timecode_start_frame`, `viewport_start_time`, `viewport_duration`, `video_scroll_offset`, `audio_scroll_offset`, `video_audio_split_ratio`, `playhead_position`.
- **Selection and drag state stay GLOBAL on `timeline_state`** — selection is global by design (the user has one selection across the whole editor) and drag is global because cross-timeline drags from one tab's view to another are supported. The original plan listed `selection_*` here; that was wrong and is now corrected per the existing per-tab listener docs in `timeline_tab.lua`.
- `tab:load_from_database()` hydrates the cache: loads tracks, clips (media+gaps via `gap_lifecycle`), per-sequence view-state from the sequence row. Asserts every required field before touching `self.cache` so a missing invariant leaves the cache untouched (rule 1.14).
- **Empty plumbing** — nothing in the codebase reads from `tab.cache` yet. The `data.state.clips == strip:get_displayed_tab().cache.clips` aliasing the original plan called for moves to Phase 1.3b (`timeline_state` accessors delegate to displayed tab) so that the bug-fix commit in 1.3a is the smallest possible change.
- Verify: targeted test `test_timeline_tab_cache_load.lua` + existing `test_timeline_tab*.lua`. Nothing else changes observably yet.

### Phase 1.2 — Cache load/evict hooks
- `TimelineTabStrip:open_record_tab` → after `TimelineTab.new`, call `tab:load_from_database()`. Idempotent re-open returns the cached object untouched (a re-click is not a reload).
- `TimelineTabStrip:open_source_tab` → both new and singleton-reload paths call `tab:load_from_database()`.
- `TimelineTabStrip:close_record_tab` / `close_source_tab` → no explicit eviction needed; the tab goes out of scope, GC collects.
- `project_changed` listener → drop all tabs (existing reset path).
- `TimelineTabStrip.deserialize` does NOT hydrate today — strip persistence is a Phase 2 concern. When Phase 2 wires the DB-backed strip, deserialize will need to call `tab:load_from_database()` for each reconstructed tab. Tracked under Phase 2.
- Lifecycle invariant pinned by `test_timeline_tab_strip_loads_cache.lua`: **every tab returned by `strip:open_*_tab` has a populated cache.** Later phases (1.3a re-pointing) rely on this so the BRE bug-fix commit can read from `strip:get_active_tab().cache` unconditionally.

### Phase 1.3a-i — Per-tab index infrastructure (empty plumbing)
- TimelineTab.cache gains `clip_lookup`, `track_clip_index`, `clip_track_positions`, `indexes_dirty` fields parallel to clip_state.lua's module-level vars.
- `tab:get_clip_by_id`, `tab:get_track_clip_index`, `tab:locate_neighbor`, `tab:invalidate_indexes` methods. Lazy rebuild on first index getter when dirty.
- `load_from_database` marks indexes dirty so freshly-loaded clips re-index on next access.
- No writer routes through these yet — that's 1.3a-ii.

### Phase 1.3a-ii — Route apply_mutations through target-tab indexes (BUG FIX — LANDED)
- `timeline_state.apply_mutations(sequence_id, mutations, callback)` resolves target tab via `strip:find_record_tab_by_sequence_id(sequence_id)` (or `get_source_tab()` if matching source).
- Target tab's `cache.clips` + indexes mutated via new `tab:apply_mutations(mutations)`.
- When target IS displayed: also call legacy `clips.apply_mutations(mutations, callback)` to mirror to `data.state` (the legacy reader path; collapses in 1.3b/c).
- When target is NOT displayed: writes land in the record's tab cache only; `data.state` untouched (correct — displayed view unchanged).
- No-tab-open case: skip (return true). Treats DB write as authoritative; next tab open hydrates fresh.
- **Read-side fix for BRE specifically** (`batch_ripple_edit.lua::build_clip_cache`): reads from `strip:find_record_tab_by_sequence_id(ctx.sequence_id).cache` instead of `timeline_state.get_all_tracks` / `get_track_clip_index` (display-tied). This fixed the long-standing "cache desync" assert pinned by `test_clip_occlusion.lua Test 4` (memory todo cleared).
- **Hydration coherence**: `timeline_state.init` re-hydrates an existing same-id tab (handles tests sharing one process across multiple DBs). `core_state.reload_clips` re-hydrates the displayed tab when it refreshes data.state.
- Pinned by `test_timeline_tab_apply_mutations.lua` (cache half) and `test_timeline_state_routes_to_target_tab.lua` (dispatch half). 842 Lua tests green.

### Phase 1.3 — Migrate readers to tab methods
- Delete `timeline_state.get_clips()`, `get_all_tracks()`, `get_track_clip_index(track_id)`, `get_sequence_id()`. Replace every callsite with `tab:get_*()` on a tab obtained via the strip:
  ```lua
  -- command code (active intent)
  local tab = strip:get_active_tab()
  local clips = tab:get_clips()

  -- view code (displayed intent)
  local tab = strip:get_displayed_tab()
  local clips = tab:get_clips()
  ```
- ~75 src callsites + ~215 test files. Each callsite: read 5-10 lines of context, pick `active` or `displayed` per intent. Most commands → active. Most view/renderer code → displayed.
- No fallback default args during migration. If you need a temporary scaffolding step, do the migration commit-by-commit (e.g., commit 2a: command callsites; commit 2b: view callsites; commit 2c: tests) rather than leaving `seq_id = seq_id or get_displayed_sequence_id()` in tree even briefly. Implicit-default arg patterns are explicitly forbidden by the project's no-fallback rule (2.13).
- After Phase 1.3 lands, `timeline_state` itself shrinks to whatever non-per-tab cross-cutting concerns remain (drag state, last_pointer_frame, color constants). If nothing remains, delete the module.

### Phase 1.4 — Signal handler dispatch (LANDED)
- `playhead_changed` mirrors the new frame to the matching tab's `cache.playhead_position` (per-sequence routing) AND updates `data.state.playhead_position` when target IS displayed (legacy reader path).
- `track_preference_changed` updates the matching track on EVERY open tab's `cache.tracks` (track preferences are persisted per-track and apply across whichever tabs hold that track).
- `media_status_changed` walks every open tab's `cache.clips` for clips referencing the changed media path (offline state is media-wide, not display-state) — plus `data.state.clips` for displayed reader compat.
- `marks_changed` / `source_loaded_changed` unchanged: marks are pulled lazily via `tab:get_marks` (no cache invalidation needed).
- Helper: `for_each_tab(fn)` iterates `strip.tabs` defensively (no-op when no strip).
- Pinned by `test_timeline_signal_handlers_per_tab.lua`.

### Phase 1.5 — Verify perf win
- Bench `switch_to_record_tab` between two ~3000-clip record tabs. Should be sub-millisecond. If it still rebuilds, you missed a hook.

### Phase 1.6 — Test + smoke (LANDED)
- Removed the `switch_to_record_tab` workaround from `tests/smoke/cases/test_source_viewer_marks_track_live_clip_mutations.py`. Smoke passes end-to-end (verified `2026-05-26`).
- Memory cleanup: `todo_test_source_viewer_marks_track_live_clip_mutations.md` marked RESOLVED with root-cause explanation; MEMORY.md index updated.
- New memory `project_per_tab_timeline_cache.md` documents the contract for future Claudes.

### Phase 1.7 — Memory + spec updates
- Update `~/.claude/projects/-Users-joe-Local-jve-spec-kit-claude/memory/todo_test_source_viewer_marks_track_live_clip_mutations.md` — mark resolved + delete TODO entry once the test passes without the workaround.
- Write a new project memory documenting the per-tab cache contract.
- Update this plan doc with a "Phase 1 complete" header noting what landed and what's deferred to Phase 2.
- Add a one-line cross-reference to `specs/015-source-in-timeline/refactor-plan.md` pointing at 022.

## Files most likely to change

- `src/lua/ui/timeline/timeline_tab.lua` — expanded with cache fields
- `src/lua/ui/timeline/timeline_tab_strip.lua` — open/close hooks load/release cache
- `src/lua/ui/timeline/state/timeline_state_data.lua`
- `src/lua/ui/timeline/state/timeline_core_state.lua`
- `src/lua/ui/timeline/state/clip_state.lua` — per-tab indexes
- `src/lua/ui/timeline/state/track_state.lua`
- `src/lua/ui/timeline/state/viewport_state.lua`
- `src/lua/ui/timeline/state/selection_state.lua`
- `src/lua/ui/timeline/timeline_state.lua` — facade either shrinks or stays, but its accessors now route through the tab
- `src/lua/core/commands/batch_ripple_edit.lua` — `build_clip_cache` reads from the active tab directly; the NSF defense's error becomes "no open tab for active seq_id" instead of "clip not in cache"
- Every caller of `timeline_state.get_clips()` / `get_all_tracks()` / `get_track_clip_index()` / `get_sequence_id()` — `git grep` for these names. ~75 src + ~215 test files.

## Commit shape

Split into ~5 commits if the diff sprawls (helps post-mortem if something breaks):
1. Phase 1.1 + 1.2 — internal restructure + lifecycle hooks
2. Phase 1.3 — migrate src callsites to `tab:get_*()` methods (delete old facade fns)
3. Phase 1.3 — migrate test callsites to `tab:get_*()` methods
4. Phase 1.4 — signal handler dispatch
5. Phase 1.6 — test workaround removal + memory updates

Commit message convention: see `git log --format='%s' | head`. Each commit ends with:
```
Authored-By: Joe Shapiro <joe@shapiro.net>
With-Help-From: Claude
```

## Mandatory pre-commit checks (each commit)

- `make -j4` clean
- `python3 -m unittest discover tests/smoke/cases -v` green
- `luacheck src tests` clean
- No `or 0` / `or default` fallbacks added (rule 2.13)
- No backward-compat shims (rule 2.15) — keep public API clean; no aliases for renamed accessors

## If something goes wrong

- **Stuck after 4 hours** without a clear path: stop, commit what's working as a WIP on a branch named `wip/022-per-tab-cache-attempt-1`, leave a `STATUS.md` in this directory describing exactly where you stopped and what's broken. Do not push.
- **Smoke fails in ways you can't diagnose**: same — WIP commit + STATUS.md.
- **You discover scope is much bigger than estimated**: phase boundaries are checkpoints. If you finish Phase 1.1-1.4 cleanly but Phase 1.5/1.6 is hairy, that's still substantial progress — commit it, leave STATUS.md.

## Forbidden — repeat from CLAUDE.md

- **No repo-wide destructive git.** Joe runs parallel Claude sessions. Untracked files = sibling work. `git status` first; scope every op to YOUR files.
- **No `/usr/bin/git`** bypassing safety hooks.
- **No "pre-existing" / "legacy" / "out of scope" excuses.** If a test fails, fix it or document precisely why it's untouchable.
- **No silent failures** anywhere in the new code.
- **TDD**: if you find a bug during this work, write the failing test FIRST, then fix.

## Reference

- BRE silent-no-op investigation + the test workaround + NSF defense: see `git log` immediately before this plan was created.
- Memory: `todo_test_source_viewer_marks_track_live_clip_mutations.md`, `todo_019_media_tc_off_media.md`.
- Spec 015 introduced the displayed/active split: `specs/015-source-in-timeline/spec.md`, `specs/015-source-in-timeline/refactor-plan.md`.
- This plan is Phase 1 of a longer journey toward `Panel` / `TabView` / `SequenceView`. Phase 2+ are not scheduled; see "Long-term target" above.
