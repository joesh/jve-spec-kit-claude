# Implementation Plan: RelinkClips

**Branch**: `002-relink-clips` | **Date**: 2026-03-14 | **Spec**: `specs/002-relink-clips/spec.md`

## Summary

Replace media-level `RelinkMedia` with clip-level `RelinkClips`. Per-clip: compute required absolute TC range, find candidates by configurable matching rules (filename, TC, resolution, fps), adjust source_in/source_out for trimmed media, create media records for segment files, atomic undo. "Matching Rules..." sub-dialog persisted per-project.

## Technical Context

**Language/Version**: Lua (LuaJIT) + C++ (Qt6)
**Primary Dependencies**: Qt6 (dialogs), ffprobe (TC probing), dkjson (JSON)
**Storage**: SQLite (.jvp project files), `~/.jve/` for app prefs
**Testing**: LuaJIT test harness, `make -j4` runs all (luacheck + Lua + C++ + integration)
**Target Platform**: macOS (Darwin)
**Project Type**: Single hybrid (Lua + C++)
**Constraints**: No schema migrations (use metadata JSON). SQL isolation (models only). Fail-fast asserts.

## Constitution Check

**I. Library-First Architecture**: ✅ `media_relinker.lua` is standalone matching logic
**II. CLI Interface Standard**: N/A — interactive editor feature
**III. Test-First Development**: ✅ TDD for TC offset math, segment matching, undo
**IV. Documentation-Driven Specifications**: ✅ Spec complete with 6 clarifications
**V. Template-Based Consistency**: ✅ Follows existing command/dialog/model patterns

## Project Structure

### Documentation
```
specs/002-relink-clips/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
└── tasks.md
```

### Source Code
```
src/lua/
├── core/
│   ├── commands/
│   │   ├── relink_clips.lua              # NEW — replaces relink_media.lua
│   │   └── show_relink_dialog.lua        # MODIFY — dispatch RelinkClips
│   ├── media_relinker.lua                # MODIFY — clip-level matching + TC offset
│   ├── command_implementations.lua       # MODIFY — swap module registration
│   └── command_registry.lua              # MODIFY — remove old alias
├── models/
│   ├── clip.lua                          # MODIFY — find_clips_for_media, set_source_range
│   └── media.lua                         # MODIFY — get_start_tc accessor
├── ui/
│   ├── media_relink_dialog.lua           # MODIFY — clip list, status icons, Rules button
│   └── matching_rules_dialog.lua         # NEW — matching criteria sub-dialog

tests/
├── test_relink_clips.lua                 # NEW — clip-level relink + TC offset
├── test_relink_segments.lua              # NEW — segment file matching
└── test_matching_rules.lua               # NEW — rules persistence
```

**Structure Decision**: Existing project structure. New files follow established patterns in their directories.

## Phase 0: Research

No technical unknowns. All building blocks already implemented and tested:

| Decision | Rationale | Alternative Rejected |
|----------|-----------|---------------------|
| Single `RelinkClips` command (not BatchCommand wrapper) | All clips processed in one pass, simpler undo state | BatchCommand adds overhead and complexity for no benefit here |
| TC stored as `(frames, rate)` in metadata JSON | Frame-rate-independent, same type as all other time values | Float seconds (ambiguous unit), TC string (requires fps to compare) |
| Per-project matching rules via `set_project_setting` | Existing pattern (browser sort, window geo). New projects inherit. | App-wide `~/.jve/` (different projects may need different rules) |
| ffprobe for candidate TC probing | Already implemented, handles video TC tags + BWF time_reference | EMP.MEDIA_FILE_OPEN (creates VT sessions, exhausts pool on rapid probing) |
| Clip-level not media-level | Media-managed segments break 1:1 media-file assumption | Media-level can't handle segments or per-clip TC offset |

## Phase 1: Design

### Data Model

**No schema changes.** All data in existing structures:

- **Clip**: `source_in_frame`, `source_out_frame`, `media_id`, `clip_kind`, `fps_numerator/denominator`
- **Media**: `file_path` (via `_file_path`), `metadata` JSON with `start_tc_value`, `start_tc_rate`
- **Project Settings**: `settings` JSON column — add `relink_matching_rules` key
- **Command History**: `command_args` JSON — stores clip-level undo state

### Core Algorithm

```
relink_clips_batch(clips, search_paths, matching_rules, progress_cb):

  1. Scan search_paths → candidate_index {basename_lower → [paths]}
     If accept_filename_suffixes: also index suffix variants

  2. For each clip (with progress):
     a. Get media record → stored start_tc (value, rate)
     b. Compute absolute TC range:
        abs_start = start_tc_value + source_in (rescaled to start_tc_rate)
        abs_end   = start_tc_value + source_out (rescaled)

     c. Find candidates:
        - If filename enabled: basename match from index
        - If TC enabled: probe each candidate's TC, check containment
        - If resolution enabled: probe and compare
        - If fps enabled: probe and compare

     d. Filter candidates that pass ALL enabled criteria

     e. If 0 candidates → mark failed
        If 1 candidate → accept
        If >1 candidates → mark ambiguous (user chooses later)

     f. If accepted candidate has different start_tc:
        - If accept_trimmed_media disabled → reject
        - Compute offset = candidate_tc - stored_tc
        - new_source_in = source_in - offset (rescaled to clip rate)
        - new_source_out = source_out - offset
        - If new_source_in < 0 → candidate doesn't contain range → reject

     g. If candidate path differs from any existing media record:
        - Create new media record + master clip
        - Record in new_media_records for undo cleanup

  3. Return {relinked, failed, ambiguous, new_media}
```

### Command Contract: RelinkClips

```
Executor args:
  clip_relink_map:   {clip_id → {new_media_id, new_source_in, new_source_out}}
  media_path_changes: {media_id → new_path}
  new_media_records:  [{id, path, name, start_tc_value, start_tc_rate, ...}]
  project_id:         string

Persisted by executor (for undo):
  old_clip_state:     {clip_id → {old_media_id, old_source_in, old_source_out}}
  old_media_paths:    {media_id → old_path}

Undo:
  1. Restore each clip's media_id, source_in, source_out from old_clip_state
  2. Restore each media's file_path from old_media_paths
  3. Delete media records listed in new_media_records
```

### UI Contract: Matching Rules Dialog

```
matching_rules_dialog.show(current_rules, parent_window)
  → returns updated rules table or nil on cancel

Rules table:
  {match_filename=bool, match_timecode=bool, match_resolution=bool,
   match_frame_rate=bool, accept_trimmed_media=bool, accept_filename_suffixes=bool}

Persistence:
  Load: database.get_project_setting(project_id, "relink_matching_rules")
  Save: database.set_project_setting(project_id, "relink_matching_rules", rules)
```

### Reuse Inventory

| Existing | Reuse |
|----------|-------|
| `progress_panel.lua` | Dialog progress display |
| `Media.begin_batch()`/`end_batch()` | Batch media updates |
| `probe_start_tc()` | Candidate TC probing (video TC + BWF) |
| `tc_to_frames()` | TC string → frames conversion |
| `file_browser.open_directory()` / `get_last_directory()` | Search dir |
| `database.get/set_project_setting()` | Matching rules persistence |
| `Sequence.ensure_masterclip()` | Master clip creation for segments |
| `scan_directory()` | Recursive file discovery |
| `build_candidate_cache()` / `ensure_candidate_cache()` | Candidate indexing |

### Key Files to Modify

| File | Change |
|------|--------|
| `src/lua/core/media_relinker.lua` | Replace `batch_relink` with `relink_clips_batch`. Add `find_candidates_for_clip`, `compute_tc_offset`, `adjust_source_range`. |
| `src/lua/core/commands/relink_media.lua` | **DELETE** |
| `src/lua/core/commands/relink_clips.lua` | **NEW** — executor + undoer with clip-level state |
| `src/lua/core/commands/show_relink_dialog.lua` | Dispatch `RelinkClips`. Gather clips not media. Handle ambiguous results. |
| `src/lua/ui/media_relink_dialog.lua` | Clip list, status icons, "Matching Rules..." button, ambiguity prompts. |
| `src/lua/ui/matching_rules_dialog.lua` | **NEW** — checkbox dialog, loads/saves project settings. |
| `src/lua/models/clip.lua` | Add `find_clips_for_media(media_id)`, `set_source_range(in, out)`. |
| `src/lua/models/media.lua` | Add `get_start_tc()` → `(value, rate)` from metadata JSON. |
| `src/lua/core/command_implementations.lua` | Replace `relink_media` with `relink_clips`. |
| `src/lua/core/command_registry.lua` | Clean up old aliases. |

## Phase 2: Task Planning Approach

**Strategy**: TDD — tests before implementation, models before algorithms before commands before UI.

**Ordering**:
1. Pure algorithm tests (TC offset math, source range adjustment) [P]
2. Model accessors (Clip.find_clips_for_media, Media.get_start_tc) [P]
3. Matching rules dialog + persistence test
4. Core relinker rewrite (clip-level matching)
5. RelinkClips command + undo test
6. Dialog updates (clip list, status icons, Rules button)
7. Integration test with real project data
8. Remove RelinkMedia, update registrations

**Estimated Output**: ~15 tasks

## Complexity Tracking

No constitutional violations.

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete
- [x] Phase 1: Design complete
- [x] Phase 2: Task planning complete (approach described)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented (none)

---
*Based on Constitution v1.0.0 - See `.specify/memory/constitution.md`*
