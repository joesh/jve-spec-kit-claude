# Coverage Results — Fix Log

**Source**: COVERAGE-RESULTS.md (26 test suites, 1595 assertions)
**Commits**: 4436ac4, af002f2, 7534d86

## Fixed (17)

| ID | Module | Bug | Commit |
|----|--------|-----|--------|
| T3 | clip_link.lua:311 | `calculate_anchor_time` queries `c.start_value` (nonexistent column) → always nil | 4436ac4 — changed to `c.timeline_start_frame` |
| T4a | command_manager.lua | `execution_depth` leaks when assert throws past `::cleanup::` label; all subsequent executes enter nested path | 7534d86 — xpcall wrapper ensures depth always decrements |
| T4b | command_manager.lua:745-793 | Nested command failure: `result.error_message` stays `""` because nested path never reads `last_error_message` | 7534d86 — nested path now reads `last_error_message` like top-level |
| T8 | error_builder.lua:196 | `build()` overwrites `technical_details` with `context` table; any details added via `withTechnicalDetails()` lost | 4436ac4 — merge context into technical_details instead of overwriting |
| T9 | snapshot_manager.lua:394 | DELETE prepared statement executed but never finalized; relies on GC | 4436ac4 — finalize after exec |
| T10 | command_schema.lua:374-375 | `apply_rules()` return values `(false, error_msg)` discarded; all validation inside apply_rules was silently a no-op (required, kind, one_of, requires_fields, requires_methods, nested fields) | af002f2 — caller checks return; also fixed kind="any" support + SetPlayhead/SetViewport schemas |
| T5a | database.lua:1411 | `load_sequence_track_heights`: `pcall(json.decode)` unreachable error branch — dkjson returns `(nil, err)`, never throws | uncommitted — replaced with direct `json.decode` call; check nil return with decode error in message |
| T5b | database.lua:1416 | JSON array/object conflation: `[1,2,3]` passes `type ~= "table"` because Lua arrays are tables; track heights must be a JSON object | uncommitted — added `decoded[1] ~= nil` check to reject arrays |
| T6a | command.lua:322 | `deserialize`: same `pcall(json.decode)` dead-branch issue as T5a | uncommitted — replaced with direct `json.decode` call; nil result returns error with decode details |
| T6b | command.lua:516 | `save()` silently falls back to `or 1` for nil fps_denominator; `serialize()` properly errors on same condition | uncommitted — removed `or 1` fallback; error on missing/zero fps_denominator, matching serialize() |
| T6c | command.lua:526 | `save()` conflates two checks: missing playhead_value and zero playhead_rate produce identical error message | uncommitted — split into two separate asserts with distinct messages |
| T8b | error_system.lua:280-292 | `format_user_error`: `.success` accessed before type check; non-table non-nil input (e.g. string) crashes on field access before reaching type guard | uncommitted — moved type check before `.success` access |
| T11 | rational.lua:255-258,282-285 | `__eq`/`__lt` number coercion paths unreachable in LuaJIT — Lua 5.1 only invokes comparison metamethods when both operands share same metatable | uncommitted — removed dead branches |
| R1 | edge_drag_renderer.lua:30,222 | `fps_den` used `or 1` fallback while `fps_num` asserted — inconsistent fail-fast behavior | uncommitted — removed `or 1`; added assert matching `fps_num` |
| R2 | clip.lua:335 | `save_internal` silently returned `false` for empty/nil clip ID (old `print` removed but not replaced with assert) | uncommitted — changed to `assert(self.id ...)` |
| R3 | delete_sequence.lua:241-243 | `view_start_frame or 0`, `view_duration_frames or 240`, `playhead_value or 0` — silent fallbacks with no stack trace if schema violated | uncommitted — replaced with `assert(tonumber(...))` matching other fields; removed redundant `or` from undo re-insertion path |
| R4 | playback_controller.lua:574,585 | Magic number `86400` for empty-timeline scrub limit; silent `or 86400` fallback if `sequence_info.total_frames` nil | uncommitted — named constant `SECONDS_PER_DAY`; moved computation to explicit `if not total_frames` block; removed `or` fallback |

## Unfixed — Design Issues (1)

| ID | Module | Issue | Severity |
|----|--------|-------|----------|
| T5c | database.lua | `save_bins`: "invalid hierarchy" error unreachable — `resolve_bin_path` auto-repairs cycles by clearing parent_id | Info (intentional) |

*T12 (clip.lua missing logger import) resolved in NSF sweep.*

## Unfixed — Architectural Observations (6)

Not bugs per se; documented for future reference.

| ID | Module | Observation |
|----|--------|-------------|
| T5d | database.lua | `build_clip_from_query_row` FATAL paths mostly unreachable — schema NOT NULL/CHECK constraints prevent those states |
| T9a | snapshot_manager.lua | `build_snapshot_payload` loads all media globally then filters by clip refs; wasteful for large libraries |
| T9b | snapshot_manager.lua | One snapshot per sequence — no history, only latest retained |
| T17 | selection_hub.lua | `register_listener` calls callback immediately without pcall; subsequent notifications are pcall-wrapped; inconsistent |
| T24 | collapsible_section.lua | ~600 of 716 LOC is pcall-wrapped Qt error handling boilerplate; actual state logic ~50 lines |
| T25 | inspector/view.lua | 1135 LOC with 10+ transitive deps — untestable without massive stub layer; pure helpers could be extracted |
