# Opt+Click Select-Linked + Mouse-Shortcut Config — Analysis

Date: 2026-05-01
Author: Claude (research only — no code changes)

## TL;DR

1. **Opt+click for select-linked is already wired end-to-end.** The reason it appears broken on the
   anamnesis-gold timeline is **bad link data from the DRP importer**, not the click path. JVE's
   timeline shows clip `13-053-001` selecting V1+V4 with no audio; Resolve shows the same clip
   linked to audio on A4 (link icon visible). The importer is producing V→V duplicate-copy link
   groups instead of V→A pair groups.
2. **Mouse-shortcut config** can mirror the keyboard system (TOML + registry + dispatch + UI), but
   needs two extensions keyboards don't have: a **region** axis (clip / edge / gap / playhead /
   ruler / track_header / empty) and a **gesture-phase** axis (click / double-click / drag /
   wheel). The actual architectural work is refactoring `timeline_view_input.handle_mouse` from
   a hard-coded if/else tree into a registry-driven dispatcher.

---

## Part 1 — Opt+Click Select-Linked

### Current wiring (verified)

**C++ → Lua modifier delivery**
- `src/timeline_renderer.cpp:288` — press packs `modifiers.alt = event->modifiers() & Qt::AltModifier`.
- Same for `release` (`:343`), `move` (`:396`), `wheel` (`:515`).

**Lua dispatch**
- `src/lua/ui/timeline/view/timeline_view_input.lua:511-516` — clip press calls
  `command_manager.execute_interactive("SelectClips", { ..., modifiers = modifiers })`.
- `src/lua/ui/timeline/view/timeline_view_input.lua:482-487` — edge press calls `SelectEdges` the
  same way.

**Command logic**
- `src/lua/core/commands/select_clips.lua:67-69` — when `modifiers.alt`, calls
  `expand_to_linked_clips(target_ids, db)` which walks `clip_links.get_link_group()` and adds
  every `enabled = true` member.
- `src/lua/core/commands/select_edges.lua:189` — analogous expansion for trim edges.

### The actual bug

Joe's screenshots compare the same project (anamnesis-gold) opened in JVE vs Resolve.

- **Resolve** (image 3): `13-053-001` on V1 has a link-chain icon next to its audio counterpart on
  A4, plus other audio matches on A3/A5. Linked V+A pair.
- **JVE** (image 2): clicking `13-053-001` on V4 selects the same name on V1 (a *video* copy on a
  different track) — NO audio gets selected. The displayed selection ("2 selected" in the
  inspector) is V+V, not V+A.

This means the DRP importer wrote `clip_links` rows that group multiple **video** instances of
the same clip together, rather than grouping each video instance with its synced audio chunk.

### Likely cause (hypothesis, needs verification)

The DRP importer probably keys link-group membership on `media_id` / clip-name rather than on
the explicit `LinkedTrackItems` / `Anchor` fields the DRP serializes. Two video copies of
`13-053-001` share the same source media, so they get pooled into one group; the audio item on
A4 carries a different media id and is left out — or pooled into its own audio-only group.

### Evidence (verified 2026-05-01)

Project: `~/Documents/JVE Projects/anamnesis-gold-timeline.jvp`
Sequence: `dabc4c90-3b95-4406-a1db-da5bded7638a` (2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE)
Clicked clip: V4 instance of `13-053-001` at timeline_start=111632, duration=113
(id `a84215d7-834a-496d-9053-5f2bc9e95190`).

Link group for clicked clip — `f3e0a0bf-5b72-4016-a1c8-aa04b5e219c7`:

| role  | track | track_type | timeline_start | duration |
|-------|-------|------------|---------------:|---------:|
| video | V1    | VIDEO      | 111632         | 113      |
| video | V4    | VIDEO      | 111632         | 113      |

Sibling audio at same TC (`13-053-001` on A4) lives in a **different** link group
`ae9e5fdb-eb80-42f2-884b-62014b75fae1`:

| role  | track | track_type | timeline_start | duration |
|-------|-------|------------|---------------:|---------:|
| audio | A4    | AUDIO      | 111626         | 155      |
| audio | A5    | AUDIO      | 111626         | 155      |

So link groups are partitioned **by track_type**, not by the V↔A relationship the DRP
serializes. The importer is grouping clips that share `(name, timeline_start, duration)` modulo
track type — i.e. duplicate copies of the same media on parallel tracks — and missing the
cross-type V+A pairing entirely.

Resolve's screenshot (image 3) confirms the truth: the V1 instance shows a chain icon next to
the A4 audio chunk for the same shot, with related audio appearing on A3/A5 — i.e. the DRP
file *does* carry the V↔A linkage; the importer is just not reading it.

### Fix (landed 2026-05-01, refined same day)

DRP carries V↔A linkage in `<LinkedItemSync>`, but the value is a **parent-take ID**, not a
pair ID. Every clip that originated from one continuous capture carries the same value —
including multiple shot-named segments produced by source-side blading. Resolve's actual
V↔A pair granularity is `(LinkedItemSync, Name)`: each shot-named segment links V to A
independently.

Empirical confirmation against the anamnesis-gold-timeline.drp fixture:
`LinkedItemSync = -2021` is shared by FOUR timeline clips —
`V 13-053-001` + `V 13-055-001` + `A 13-053-001` + `A 13-055-001` (two adjacent shots
bladed from one take). Resolve renders this as TWO separate chain icons, not one 4-clip
group. Initial fix grouped on `LinkedItemSync` alone and produced a 4-member group; the
refined fix composes the pair key as `"<sync_value>:<clip_name>"`. The sole `LinkedGroup`
UUID field that 989 video clips share is video-only colour/grade grouping (585 V members
in one bucket, 0 A members), unrelated to V↔A pair linkage.

Changes:
- `src/lua/importers/drp_importer.lua` `parse_resolve_tracks` now reads
  `<LinkedItemSync>` and surfaces it on `clip_data.linked_item_sync`. Empty/missing →
  nil. Non-numeric content → fail-fast assert (Rule 1.14).
- `src/lua/importers/importer_core.lua` STEP 6 replaces the
  `(file_uuid, timeline_start)` heuristic with grouping by `linked_item_sync`. Clips
  without a link ID are not collected at all, so cannot end up in any group. Architectural
  cleanup: removes a fallback that was masking the bug (Rule 2.4 / 2.13).
- `tests/test_drp_linked_item_sync.lua` — pure-Lua parser unit test on synthetic XML
  trees. 6 cases covering present / absent / empty `<LinkedItemSync>` on V and A.
- `tests/synthetic/integration/test_drp_av_link_groups.lua` — end-to-end test using the real
  anamnesis-gold-timeline.drp fixture via `--test` mode. Asserts that the V at
  timeline_start=111632 and the A at 111626 (both `13-053-001`) end up in the same
  `clip_links` group, and that the parallel V duplicate on a higher track is in no
  group at all. Verified passing: linked V on track_index=1, parallel duplicate on
  track_index=4 (matches the Resolve screenshot exactly).
- All 674 Lua unit tests still pass; both DRP integration tests pass.

Known follow-ups (not addressed in this fix):
- **Other importers regress on auto-linking**: `fcp7_xml_importer.lua`,
  `prproj_importer.lua`, and `resolve_database_importer.lua` previously got V↔A
  links from the (file_uuid, timeline_start) heuristic. They now produce no links
  until each parser is updated to extract its format's explicit link ID
  (FCP7 `<linkclipref>`, prproj `LinkedClipRef`, Resolve DB's links table). Better
  no link than wrong link, but worth tracking as a TODO.
- **Existing imported `.jvp` files retain bad links** until re-imported. The fix is
  parser-side; it does not retroactively rewrite already-imported projects. Joe's
  anamnesis-gold-timeline project needs a re-import to pick up correct links.
- **Audio-only `13-053-001` chunks on A4+A5** in the original-data screenshot were
  pooled together (`ae9e5fdb` group). Under the new logic they're now unlinked (no
  shared LinkedItemSync) — which matches Resolve's separate-chain-icons rendering.

### Field-name nit while we're here

`select_clips.lua:215` returns `expanded_linked = modifiers.option and ...`, but the C++ side only
sets `alt` (never `option`). This is a latent but inert bug — only the `expanded_linked` flag in
the result is wrong; the actual selection works because the *behaviour* check at `:67` reads
`modifiers.alt`. Decide on one canonical name (`alt` is closer to Qt; `option` is closer to Mac
labelling) and rename the other.

---

## Part 2 — Mouse Shortcut Config

### Goal

Lift the hard-coded mouse handlers to a TOML-driven registry, parallel to keyboard shortcuts, so
users can rebind gestures (and we can separate "what gesture" from "what command").

### Reference: how keyboard config works today

| Layer | File | Role |
|---|---|---|
| TOML format | `keymaps/default.jvekeys` | `"Cmd+Shift+S" = "Command [args] [@context]"` |
| Parse | `core/keyboard_shortcut_registry.lua:65 parse_shortcut`, `:568 load_keybindings` | TOML → `{key, modifiers, command, contexts}` indexed by `"key_modifiers"` combo string |
| Dispatch | `:647 handle_key_event(key, modifiers, context)` | Combo lookup → first context match → `command_manager.execute_interactive` |
| Persistence | `core/user_keymap_store.lua` | User overrides, presets |
| UI | `ui/keyboard_customization_dialog.lua`, `ui/keyboard_picture.lua`, `ui/keyboard_renderer.lua` | Visual rebinding |
| Entry point | C++ key event → Lua handler in `core/keyboard_shortcuts.lua` | Calls registry |

Key observations:
- Single source of truth: `M.keybindings`, keyed by combo string.
- Two-pass dispatch: context-specific bindings beat global.
- `register_command()` provides metadata (category, name, description) for the editor dialog,
  separate from the binding itself.

### Symmetric mouse architecture

#### A. Gesture grammar

```toml
# Format: "[Modifiers+]Button[+Phase][@Region]" = "Command [args] [@context]"
#
# Modifiers : Cmd | Ctrl | Alt | Shift   (same as keyboard)
# Button    : Left | Right | Middle | Wheel
# Phase     : Click (default) | DoubleClick | Drag
# Region    : clip | edge | gap | playhead | ruler | track_header | empty
# Context   : @timeline | @source_monitor | @timeline_monitor | @project_browser

[Selection]
"Left+Click@clip"            = "SelectClips                  @timeline"
"Cmd+Left+Click@clip"        = "SelectClips toggle=true      @timeline"
"Shift+Left+Click@clip"      = "SelectClips range=true       @timeline"
"Alt+Left+Click@clip"        = "SelectClips expand_linked=true @timeline"

[Edges]
"Left+Click@edge"            = "SelectEdges                  @timeline"
"Alt+Left+Click@edge"        = "SelectEdges expand_linked=true @timeline"

[Context]
"Right+Click@clip"           = "ShowClipContextMenu          @timeline"
"Right+Click@empty"          = "ShowTimelineContextMenu      @timeline"

[Drag]
"Left+Drag@clip"             = "MoveClips                    @timeline"
"Alt+Left+Drag@clip"         = "DuplicateClipsByDrag         @timeline"
"Left+Drag@edge"             = "TrimEdge                     @timeline"
"Left+Drag@empty"            = "RubberBandSelect             @timeline"
"Middle+Drag@timeline"       = "PanViewport                  @timeline"
"Left+Drag@playhead"         = "ScrubPlayhead                @timeline"

[Other]
"Left+DoubleClick@clip"      = "OpenInSourceMonitor          @timeline"
"Left+DoubleClick@gap"       = "SelectGap                    @timeline"
"Wheel@timeline"             = "ScrollTimeline               @timeline"
"Cmd+Wheel@timeline"         = "TimelineZoomAtMouse          @timeline"
```

The **region axis** is the major addition over keyboards. Keyboards always operate on whatever
panel has focus; mice operate on the specific element under the cursor. Hit-testing is already
done in `timeline_view_input.lua` via `pick_edges_for_track`, `find_clip_under_cursor`,
`find_gap_at_time`, etc. — those become the region classifier feeding the registry.

#### B. New files (mirror the keyboard ones)

- `keymaps/default.jvemouse` — separate file, same TOML library. Keeps key vs mouse cleanly
  partitioned and makes presets/customization independent.
- `src/lua/core/mouse_shortcut_registry.lua` — `parse_gesture`, `load_gestures`,
  `handle_mouse_event(event)`, conflict detection, `register_command` (or share the keyboard
  registry's command catalog).
- `src/lua/core/user_mousemap_store.lua` — disk-backed presets, parallel to `user_keymap_store`.
- `src/lua/ui/mouse_customization_dialog.lua` — eventually. Not blocking for v1.

#### C. Refactor `timeline_view_input.handle_mouse`

Today (`timeline_view_input.lua:444`) the function is a hard-coded chain:

```
press →
  right click? → context menu
  pick_edges? → SelectEdges
  click hits clip? → SelectClips
  click hits playhead? → start playhead drag
  else? → potential rubber band
```

After refactor:

```
press →
  region, target = hit_test(view, x, y)
  event = { type = "press", button, modifiers, region, target, x, y }
  potential_drag = mouse_shortcut_registry.resolve(event)
  -- registry returns one of:
  --   { command = "SelectClips", params = ..., on_release = "click" }
  --   { command = "MoveClips",   params = ..., on_drag = true }
  --   { command = nil }  (no binding for this combination)
  if potential_drag.command_for_press then run it now
  -- else wait for move/release to discriminate click vs drag

move (past threshold) →
  if potential_drag.on_drag → kick into drag mode for that command

release →
  if dragged → drag command finalises
  else → potential_drag.on_release fires (i.e. the click command)
```

Key constraints this keeps from the current code:
- `DRAG_THRESHOLD` discrimination stays in the input layer.
- Drag lifecycle (`potential_drag` → `drag_state` → release) stays. Bindings just declare which
  phase they consume.
- Hit-testing stays in `timeline_view_input` — registry receives the already-classified region.

#### D. Modifiers come from one source

`timeline_renderer.cpp` already packs `{ctrl, shift, alt, command}` identically across press /
release / move / wheel. Reuse as-is — no C++ changes needed for v1.

#### E. Context still applies

`@timeline`, `@source_monitor`, etc. work the same way as today (panel focus). `region` is an
orthogonal hit-test axis. Both filter independently.

### Minimum-viable v1 scope (suggestion)

Scope down to make this shippable:

1. **Click + double-click + wheel only.** Drag stays hard-coded for v1.
   - Drags have lifecycle complications (start/move/end states, snapping callbacks, undo
     groups) that don't fit a one-line TOML binding cleanly.
   - Punt drag until a clear command-stream API exists (separate spec).
2. **Timeline panel only.** Browser/inspector/source-monitor mouse handling can come later.
3. **Region taxonomy: closed list.** `clip | edge | gap | playhead | ruler | track_header |
   empty`. Easy to extend later; locking it down avoids early bikeshedding.
4. **Reuse keyboard's command registry.** A command is a command — `SelectClips` doesn't care
   if it was triggered by `Cmd+A` or `Alt+Click`. The mouse registry registers *gestures* against
   already-registered commands. One catalog, two binding tables.

### File-touch estimate (v1 scope)

| File | Change |
|---|---|
| `keymaps/default.jvemouse` | NEW — initial bindings |
| `src/lua/core/mouse_shortcut_registry.lua` | NEW — parse + dispatch |
| `src/lua/core/user_mousemap_store.lua` | NEW — persistence |
| `src/lua/ui/timeline/view/timeline_view_input.lua` | Refactor `handle_mouse` press-path to dispatch through registry |
| `src/main.cpp` or bootstrap path | Load `default.jvemouse` at startup (mirror keyboard) |
| Tests under `tests/` | New `test_mouse_shortcut_registry.lua`, gesture-parse unit tests, dispatch tests |

C++ changes: none (existing modifier delivery is sufficient).

---

## Unresolved Questions

- DRP link bug: confirm with `clip_links` dump for `13-053-001` before fixing? want regression test first?
- field name `alt` vs `option` — pick one; `select_clips.lua:215` is currently inconsistent.
- separate `default.jvemouse` file or `[Mouse.*]` sections in `default.jvekeys`?
- region taxonomy — locked list ok? extension policy?
- v1 scope: drags configurable now, or punt to v2?
- timeline only for v1, or all panels?
- conflict policy: same as keyboard (refuse unless `force=true`) or relaxed (region disambiguates)?
