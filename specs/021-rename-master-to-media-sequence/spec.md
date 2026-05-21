# Feature Specification: Rename "master clip" → "media sequence", "regular sequence" → "clip sequence"

**Feature Branch**: `021-rename-master-to-media-sequence`
**Created**: 2026-05-19
**Status**: Draft (renumbered 019 → 020 on 2026-05-19, then 020 → 021 on 2026-05-20 to put `020-debug-terminal` ahead per implementation order)

---

## Why this spec exists

The V13 schema refactor (013-timeline-placements-as) collapsed the data model into:
- One `clips` table with a single `sequence_id` pointer at any sequence.
- One `sequences` table with `kind ∈ {'master','sequence'}`.

The schema is correct. The **vocabulary** is not. Three problems remain:

1. **"master clip"** survives everywhere — as variable names, function names, item_type strings, comments, tag-service entity_types, importer parsers. Under V13 a "master clip" is just a sequence with `kind='master'`; the word "clip" in that phrase is misleading — there is no clip row.
2. **"master"** carries no content hint. The new name should describe what's INSIDE the sequence: a media-kind sequence holds media_refs; a clip-kind sequence holds clips.
3. **Item-type strings** are doubled up: `master_clip` and `timeline_clip` both route to the clip schema; `timeline_sequence` and `timeline` both route to the sequence schema. Inspector and selection_hub consumers should see ONE clip type and ONE sequence type.

This spec renames the model vocabulary throughout the codebase, drops the legacy doublets, and renames the misleading `clips.master_layer/audio_track_id` columns.

---

## Domain Model (new vocabulary)

The remainder of this spec uses these terms precisely:

- **Sequence** — a top-level container. The `sequences` table stores all of them; `kind` is the structural discriminator.
- **Sequence kinds** — exactly **two** values: `'media'` and `'clip'` (was `'master'` and `'sequence'`).
- **Media sequence** (`kind='media'`) — tracks hold **media_refs only**. Represents one continuous capture; MAY hold media_refs pointing at multiple files at heterogeneous rates. Carries `(fps_numerator, fps_denominator)`; per-stream audio rates live on each media_ref (per 018).
- **Clip sequence** (`kind='clip'`) — tracks hold **clips only**, never media_refs. Each clip has `sequence_id` pointing at another sequence — a media sequence OR another clip sequence. This is how nesting works. This is what users edit ("the timeline").
- **Clip** — a row in `clips`. Always lives inside a clip sequence. Its `sequence_id` references the sequence it sources from (media or clip; uniform).
- **Loading into the source viewer** — only sequences load. Both kinds are valid sources. The unified "clip" the source viewer represents is conceptual: it's a sequence chosen to play.

### Two orthogonal naming axes (do not confuse)

The vocabulary has two independent axes — structural and relational — and they commute. Confusing them is the trap 019 exists to prevent.

| | Names the content (structural) | Names the relationship (role) |
|---|---|---|
| **Media kind** (`kind='media'`) | media sequence | — |
| **Clip kind** (`kind='clip'`) | clip sequence | — |
| **What a clip references** | — | source sequence |
| **What owns a clip** | — | owner sequence |

- **media / clip** = structural pair, describes what's inside the sequence row.
- **source / owner** = relational pair, describes a sequence's role from a clip's perspective.

Both halves of the table are needed: "this clip's source sequence is a media sequence" or "this clip's source sequence is a clip sequence" both read cleanly. **"Source sequence" is a role name, not a kind name** — do not also use it to mean kind='media'. (This was a draft-stage tempting alternative for the kind name; rejected because it would collide with the 018-established relational meaning.)

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT the rename achieves and WHY
- ❌ Avoid HOW (no commit ordering, no exact regex patterns; that lives in tasks.md)
- 👥 Mechanical rename + minor structural collapse; no behavior change

---

## User Scenarios & Testing

### Primary user story
A developer (current or future Claude session) reads any file in the repo and understands the model from local names. No mental translation table. Searching `media sequence` finds the file-wrapping kind; searching `clip sequence` finds the timeline kind; searching `master` finds nothing in this codebase (except where it refers to **timecode master clock**, which is a different concept and stays).

### Acceptance scenarios

1. **Browser → source viewer** — User double-clicks a media sequence in the browser. Source viewer loads it. Browser-selection publish carries `item_type="sequence"` with the sequence row attached (`sequence.kind="media"`). Source viewer's own publish on load also carries `item_type="sequence"`. Inspector renders the sequence schema.
2. **Browser → timeline** — User double-clicks a clip sequence (regular sequence / nested timeline) in the browser. The TIMELINE panel loads it as the active record sequence (NOT the source viewer; different `activate_item` branch). Browser-selection publish carries `item_type="sequence"` with `sequence.kind="clip"`. Inspector renders the sequence schema.
3. **Timeline clip selection** — User clicks a clip on the timeline. Selection hub publishes `item_type="clip"` — a real `clips`-table row, the only place this item_type appears in 019. Inspector renders the clip schema for the placement row.
4. **Code search** — `rg 'master_clip|master_sequence|is_master|kind = .master.'` in `src/lua/` returns zero matches outside of allowlisted strings in `test_no_legacy_identifiers.lua`.
5. **Schema bump** — Joe regenerates `Untitled Project.jvp` from the new schema; the project opens cleanly. No migration code lands (per `feedback_schema_bump_freely`).

### Edge cases

- **`master_clock_hz`** (project audio clock from 018) stays. Different concept — timing reference, not sequence kind. This spec touches **sequence-kind vocabulary only**, not clock/timecode terminology.
- **DRP / FCP7 XML parsers** read external file formats whose element names contain `MasterClip`. Parser function names rename (`parse_master_clip_element` → `parse_media_sequence_element`) but the literal string `"MasterClip"` matched against XML stays — that's input data, not our vocabulary.
- **Inspector item_type strings**: the inspector currently accepts FOUR strings (`master_clip`, `timeline_clip`, `timeline_sequence`, `timeline`). 019 collapses these to TWO (`clip`, `sequence`). All publishers update. No backward compatibility alias.

---

## Functional Requirements

### Schema (V11 → V12)

- **FR-001** `sequences.kind` accepts exactly `'media'` and `'clip'`. The CHECK constraint enforces this. All existing rows in test fixtures and the schema-creation path rewrite to the new values.
- **FR-002** `clips.master_layer_track_id` → `clips.source_video_track_id`. Per-clip selector for which video track of the **referenced source sequence** this clip exposes. The rename uses `source_*` (not `target_*`) for two reasons: (a) it accurately describes the column — the track lives in the source sequence the clip points at via `sequence_id`, not the owner sequence — and (b) `target_*_track_id` is already taken by the Insert/Overwrite/Duplicate **command parameters** which mean "which track of the OWNER sequence to place the clip onto" (the destination); colliding the two namespaces would be a regression. The `layer` token also drops because the column is a track id, not a layer index.
- **FR-003** `clips.master_audio_track_id` → `clips.source_audio_track_id`. Same rationale.
- **FR-004** All triggers, indexes, and foreign-key references that name the old columns or kind values rename in lockstep.

### Model layer

- **FR-005** `Sequence:is_master()` → `Sequence:is_media_sequence()`. Returns `true` iff `kind == 'media'`.
- **FR-006** `Sequence.ensure_master(...)` → `Sequence.ensure_media_sequence(...)`.
- **FR-007** `Sequence.find_master_for_media(...)` → `Sequence.find_media_sequence_for_media(...)`.
- **FR-008** Any other `Sequence.*_master_*` member renames to `*_media_sequence_*`.

### Database layer

- **FR-009** `database.load_master_clips(project_id)` → `database.load_media_sequences(project_id)`. Returns rows from `sequences WHERE kind='media'`.
- **FR-010** `database.load_master_clip_bin_map` → `database.load_media_sequence_bin_map`.
- **FR-011** `database.save_master_clip_bin_map` → `database.save_media_sequence_bin_map`.
- **FR-012** `database.assign_master_clip(s)_to_bin` → `database.assign_media_sequence(s)_to_bin`.
- **FR-013** `build_master_clip_entry` (internal helper) → `build_media_sequence_entry`.
- **FR-013a** The legacy `clip_id` alias field on browser entries (`database.build_master_clip_entry` returns `clip_id = seq_id`, database.lua:1374) is **removed**. Browser entries carry `sequence_id` only. There is no `clips`-table row for a media sequence — exposing the sequence_id under a `clip_id` label was V8 carry-over and actively misled the reader into thinking a clip row existed. All consumers of the old `clip_id` field (`project_browser.master_clip_map` lookups, `activate_item`, copy/move-to-bin paths) read `sequence_id` instead.

### Source viewer

- **FR-014** `source_viewer.load_master_clip(seq_id, opts)` → `source_viewer.load_sequence(seq_id, opts)`. The argument is a sequence_id of any kind and the function loads a sequence. The word "clip" was always misleading here: there is no `clips`-row involved — the source viewer holds a sequence (see Domain Model: clips do not live outside clip sequences).
- **FR-015** `master_seq_id` parameter names rename to `sequence_id` throughout source_viewer and its callers.
- **FR-015a** `M.load_master_clip` retains no alias. Callers (`project_browser.activate_item`, `commands/match_frame`, `commands/find_source_in_browser`'s reverse-direction analogue if added, `ui.layout`) update in lockstep.

### Project browser

- **FR-016** `project_browser.master_clip_map` → `project_browser.media_sequence_map`.
- **FR-017** `project_browser.get_selected_master_clip()` / `get_selected_master_clips()` → `get_selected_media_sequence()` / `get_selected_media_sequences()`.
- **FR-018** `project_browser.focus_master_clip(seq_id, opts)` → `project_browser.focus_media_sequence(seq_id, opts)`.
- **FR-019** `project_browser.add_master_clip_item` → `add_media_sequence_item`.
- **FR-020** `browser_state.normalize_master_clip(item, ctx)` → `normalize_media_sequence(item, ctx)`. The published item_type changes (FR-024).
- **FR-021** `project_browser.activate_item` branches on `item_info.type == "media_sequence"` (was `"master_clip"`).

### Commands

- **FR-022** Command renames (kebab→CamelCase):
  - `delete_master_clip` → `delete_media_sequence` (Lua file + `DeleteMasterClip` command spec → `DeleteMediaSequence`)
  - `duplicate_master_clip` → `duplicate_media_sequence`
  - `set_master_default_layer` → `set_media_sequence_default_layer`
  - `grow_master_medium` → `grow_media_sequence_medium`
  - `find_master_clip_in_browser` → `find_source_in_browser`. The rename drops the kind word entirely. The command reveals **whatever sequence this timeline clip sources from**, kind-agnostic — if the clip points at a media sequence, that's revealed; if it points at a nested clip sequence, that's revealed. Naming it after a kind would lock it to one case and force a duplicate command for the other; naming it after the relational role (source) keeps it unified with the source/owner axis defined in the Domain Model above.
  
  Old command names removed. No alias retained. Keybindings and menu wiring update in lockstep.

### Selection hub item_type strings (the doublet collapse)

- **FR-023** Inspector recognizes exactly TWO item_type values:
  - `"clip"` — routes to clip schema (for `clips` rows in a clip sequence)
  - `"sequence"` — routes to sequence schema (for sequences loaded as inspection targets — e.g., the source viewer's loaded sequence, or a sequence selected in the browser)
- **FR-024** Browser publishes `item_type="sequence"` for BOTH media sequences (was `"master_clip"`) and clip sequences (was `"timeline"`). A browser entry is always a sequence row — there is no `clips`-table row in the browser (see Domain Model). The structural kind lives on the published `sequence.kind` field; consumers that need to branch on it read it from there. Inspector renders the same sequence schema for both kinds; kind-specific fields, if any, are gated inside the schema.
- **FR-025** Timeline panel publishes `item_type="clip"` for selected clip rows (was `"timeline_clip"`). These are real `clips`-table rows — placements inside a clip sequence. The only publisher of `item_type="clip"` in the codebase.
- **FR-026** Source viewer publishes `item_type="sequence"` for the loaded sequence (was `"timeline"` per the simple fix in master prior to 019).
- **FR-027** `selection_binding.resolve_inspectables` accepts ONLY `"clip"` and `"sequence"`. Receiving any other item_type asserts. No silent skip.

### Tag service

- **FR-028** `tag_service.list_master_clip_assignments` → `tag_service.list_media_sequence_assignments`.
- **FR-029** All `entity_type = "master_clip"` strings passed to tag service → `entity_type = "media_sequence"`.

### Importers

- **FR-030** `drp_importer.parse_master_clip_element` → `parse_media_sequence_element`. The XML element name being matched (literal `"MasterClip"` from DRP files) is not renamed — that's input format.
- **FR-031** `fcp7_xml_importer.find_existing_master_clip(media_id)` → `find_existing_media_sequence(media_id)`.
- **FR-032** `importer_core.pool_master_clips` → `pool_media_sequences`.

### Banned-word linter

- **FR-033** `test_no_legacy_identifiers.lua` adds the V13 vocabulary to its banned list:
  - `master_clip` (any form: snake, Camel, kebab)
  - `master_sequence`
  - `is_master` (as a method or variable)
  - `master_layer_track_id`, `master_audio_track_id`
  - `kind = 'master'` / `kind = 'sequence'` (string literals matching the old enum)
  
  Allowlist exceptions: XML parser literal matches against DRP/FCP7 source files, and `master_clock_hz` (different concept).

### Comments and logs

- **FR-034** Every comment or log message containing "master clip" referring to a kind='media' sequence rewrites to "media sequence". Same for "regular sequence" / "timeline sequence" → "clip sequence" where the meaning is the kind='clip' row (not the user-facing word "timeline" for the editing surface, which stays).

### Tests

- **FR-035** All test fixtures that `INSERT INTO sequences` with `kind='master'` or `'sequence'` rewrite to `'media'` / `'clip'`.
- **FR-036** Test assertions naming the old vocabulary (e.g. `item.item_type == "master_clip"`) rewrite to the new value. Tests that assert the doublet behavior (multiple item_type values mapping to one schema) are removed; FR-027 makes them moot.

### User-facing strings (separate axis)

The code rename is internal. User-visible labels follow industry conventions independently.

- **FR-037** User-facing strings (menu labels, window titles, status-bar text, tooltips, on-screen panel headers) that refer to a media sequence in 019 vocabulary **continue to say "Master Clip"**. This is decoupled from the code rename.
- **FR-037a** Rationale — alignment with established NLE terminology:
  - **Avid Media Composer**: "Master Clip" — the bin-level reference object pointing at MXF media. ([Avid Media Composer User's Guide](https://resources.avid.com/SupportFiles/attach/MC_UserGuide.pdf))
  - **Adobe Premiere Pro**: "Source Clip" (formerly "Master Clip"; Adobe explicitly notes the rename and treats it as the parent of timeline-instance child clips). ([helpx.adobe.com](https://helpx.adobe.com/premiere-pro/using/master-clip-effects.html))
  - **DaVinci Resolve**: "Media Pool clip" / informally "source clip"; conforming and relinking are defined relative to the Media Pool clip as the source. (Blackmagic DaVinci Resolve Manual, Conforming and Relinking Media section)
  
  All three converge on the same concept. Avid kept "Master Clip"; we follow Avid for user-facing strings because (a) the label is recognizable across all three editor user bases (Premiere users will recognize the renamed-from term, Resolve users use it informally), and (b) keeping the internal vs. external vocabularies decoupled is cleaner than re-litigating the user-facing label every time we rename a column.
- **FR-037b** Settings keys persisted to disk (project_settings JSON, `~/.jve/*.json`) and similar machine-readable persisted strings are NOT user-facing and follow the **code rename**, not the UI strings. If any current setting key contains `master_clip` it renames to `media_sequence` in lockstep with the code (these are read/written by Lua, not seen by users).

---

## Out of scope

- **Sequence model semantics** — no behavior change. Sequences still load identically; clips still resolve identically. Renames only.
- **Migration code** — schema bump is uncompromising per `feedback_schema_bump_freely`. Joe regenerates the project DB; no `.jvp` migration path lands.
- **C++ side** — no C++ enum or string carries the old vocabulary in a way that ripples to the Lua side beyond what already routes through `kind` strings. If any C++ string compares against `"master"`, it renames in lockstep.
- **`master_clock_hz`** stays. That's a project audio clock from 018, unrelated to sequence kind.
- **"Master" as in "master volume" / "master timecode" / "master audio bus"** — distinct concept, retained.

---

## Open questions

- (none currently outstanding — user-facing strings policy resolved in FR-037; 018 forward-ref deferred until 019 implements per Joe 2026-05-19.)
