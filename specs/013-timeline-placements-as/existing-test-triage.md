# T007a: Existing-Test Triage

**Rule 2.31 gate**: classify every `tests/**` file touching dropped identifiers before T008 lands.

## Scope (top-level)

| Metric | Count |
|---|---|
| Total `tests/test_*.lua` files | 685 |
| Files touching banned identifiers | 235 (~34%) |
| `tests/synthetic/helpers/*.lua` touching banned identifiers | 3 |

### Banned-identifier occurrence (file count)

| Identifier | Files |
|---|---|
| `clip_kind` | 175 |
| `master_clip_id` | 77 |
| `kind='timeline'` (seq literal) | 55 |
| `kind='masterclip'` (seq literal) | 16 |
| `clip.media_id` (narrow) | 6 |
| `.offline` (includes noise) | 29 |

### `clip_kind` value breakdown

| Value | Files |
|---|---|
| `clip_kind='master'` → remaps to `media_refs` table | 20 |
| `clip_kind='timeline'` → remaps to `clips` with `nested_sequence_id` | 24 |
| Other / infrastructure | 131 (most of these only touch `clip_kind` in DB-setup boilerplate) |

### Shared helpers that encode the old schema

- `tests/test_env.lua` (1 hit) — ultimate fan-out; changing this affects every test.
- `tests/synthetic/helpers/ripple_layout.lua` (3 hits) — ASCII-DSL ripple test runner.
- `tests/synthetic/helpers/project_validator.lua` (14 hits) — schema assertions.

## Character of the work

This is **not** "classify a handful." It is "rewrite or regenerate roughly a third of the test suite to match the new three-table model." The economics change the strategy:

### Option A — hand-classify all 235 files (what the task naively reads)

- Estimated effort: ~1–2 days of Claude token budget just on classification.
- High risk of inconsistency across the triage (drift between early and late decisions).
- Produces a committed ledger useful for audit but redundant with the resulting diff.

### Option B — bulk strategy (recommended)

1. **Rewrite the 3 helpers first**. Drive ~60–80% of tests to compile against the new schema for free: `test_env.lua` sets up a `kind='master'` + media_refs instead of `clip_kind='master'` clip rows; `project_validator.lua` asserts new invariants (INV-1..INV-8); `ripple_layout.lua` builds nested-sequence placements.
2. **Bulk regex-migrate the obvious cases**. Files whose only contact with the old schema is `clip_kind='timeline'` in `Clip.create(...)` call sites get mechanically rewritten: strip `clip_kind`, swap `master_clip_id` → `nested_sequence_id`. Tooling: one-shot Lua migration script committed at `scripts/migrate_test_schema.lua`, run once, reviewed in diff.
3. **Hand-classify only the outliers** (estimated 20–40 files): tests that specifically exercise removed code paths (e.g. old-Insert flattening logic) → DELETE; tests that assert on `clips.offline` column semantics → REWRITE as chain-derived offline per new renderer contract.
4. **T108a standing grep-test catches everything the regex missed** after T008 lands.

### Option C — defer triage until T008 lands

Let T008 break everything; fix tests as each phase's impl lands. Violates rule 2.31 (silent expectation-rewrite) but is tempting for speed.

## Recommendation

**Option B**. The triage artifact becomes a short planning doc (this file) plus a committed migration script, rather than a 235-row spreadsheet. Rule 2.31 is satisfied: the decision to migrate mechanically is explicit and auditable via the script diff; any failure of a mechanically-migrated test is an observable red, not a silent green.

## Joe-review gate

This is where tasks.md hands off for scope decision:

**Q1**: Option A, B, or C?
**Q2**: If B: are the 3 helpers' rewrites on-path for my work, or should they be a sibling Claude session's scope (given the emp_*/peak_cache uncommitted work on this branch is another session)?
**Q3**: Any test file I should explicitly DELETE rather than migrate because its code path is now gone (e.g. tests asserting on the flattening behavior of old Insert)?

**Recommendation to proceed**: Option B, helpers rewritten first in a small isolated commit, then T008 schema rewrite, then the migration script in a second commit, hand-classify outliers in a third.

## Discovered outliers (Q3 from Joe)

After Joe confirmed Option B + "you have to discover" the DELETE-vs-REWRITE boundary:

### Concrete DELETE candidates — behaviors removed by FR-018

| File | Why DELETE |
|---|---|
| `tests/test_insert_rescales_master_clip_to_sequence_timebase.lua` | Tests Insert-time rescaling of source_in/out when masterclip fps ≠ timeline fps. Under the new model Insert never rescales; cross-timebase handling moves to `fps_mismatch_policy` + resolver-time conversion per FR-015 / CT-R8. The behavior this file asserts is gone. |
| `tests/test_overwrite_rescales_master_clip_to_sequence_timebase.lua` | Same reason as Insert: mutation-time rescaling is removed. |
| `tests/test_delete_master_clip.lua` | Tests dedicated `DeleteMasterClip` command. Under the new model masters are sequences; standard sequence-delete handles the case. Cycle-DAG and child cleanup concerns move to DeleteSequence + INV-3. |
| `tests/test_duplicate_master_clip.lua` | Same: dedicated DuplicateMasterClip gone; sequence duplication handles it. |
| `tests/test_sequence_masterclip_methods.lua` | Helpers tied to the old `kind='masterclip'` naming + clip-row-representation. Coverage of the surviving behaviors (identity, descent, timebase queries) moves to new `ensure_master` / resolver tests. |

5 DELETE candidates total.

### Concrete REWRITE candidates — domain behavior survives, shape changes

| File | Why REWRITE (shape swap, semantics preserved) |
|---|---|
| `tests/test_ensure_masterclip.lua` | `ensure_masterclip()` → `ensure_master()`. Inside the master, the created rows are `media_refs` (not `clips` with `clip_kind='master'`). All other behaviors preserved. |
| `tests/test_ensure_masterclip_uses_media_audio_rate.lua` | Same rename + shape swap; the "audio_sample_rate is rigorously populated, no 48kHz fallback" behavior (recently tightened) must stay asserted. |
| `tests/test_clip_mutator.lua` | Mutator operates on `clips` rows; after T008 those rows no longer carry `media_id`/`clip_kind`/`offline`. Assertions must pivot to new columns (`nested_sequence_id`, `master_layer_track_id`). |
| `tests/test_duplicate_clips_preserves_structural_fields.lua` | "Structural fields" list changes: adds `master_layer_track_id`, `fps_mismatch_policy`, `clip_channel_override` row copy (CT-C8); removes `media_id`/`clip_kind`. |
| `tests/test_renderer_tmb.lua` | TMB still sees flat entries, but upstream now comes from `pick_in_range` (T031 wrappers). Assertions on entry shape stay; DB-setup flips to new schema. |
| `tests/test_inspectable_display_values.lua` | Inspector fields per CT-IN1..IN4 — the fields themselves change (layer override, per-channel overrides, etc.), so this test is partially rewritten and partially superseded by T084/T086. |
| `tests/test_playback_engine_media_status.lua` | `clip.offline` column is gone; offline is chain-derived. Assertions pivot to the derived-offline path (see CT-RN3). |
| `tests/test_project_browser_offline_stamp.lua` | Same: offline is a derived state, not a stored column. Browser row still shows "offline" — but derived. |

8+ REWRITE candidates identified; the bulk-migration script handles another ~120 mechanical cases (tests that only touch `clip_kind`/`master_clip_id`/`kind='timeline'` in DB-setup boilerplate).

### Remainder

Roughly 100 test files that reference banned identifiers ONLY in set-up boilerplate (e.g. creating a seed clip row with `clip_kind='timeline', master_clip_id='x'`). The `scripts/migrate_test_schema.lua` migration script handles these mechanically; T108a catches anything the regex misses.

## Joe-review gate — updated

**Q1 (already answered)**: B.
**Q2 (already answered)**: mine.
**Q3 (asked)**: DELETE the 5 files above; REWRITE the 8 files above; bulk-migrate the ~120 boilerplate-only files via a committed script; hand-classify any surprise at migration time. Proceeding if you agree.

## Unresolved

- Fixture regeneration scope overlaps with T109 (deferred there).
- `test_env.lua` is loaded by ~every test — changing it is a build-break moment. Must land atomically with T008.
- `tests/synthetic/helpers/ripple_layout.lua` builds old-shape timeline clips via its ASCII DSL — DSL surface stays, internal construction swaps to the new shape. Small but must land atomically with T008 + helper rewrite.
- `import_schema.lua` (referenced by some tests via `require("import_schema")`) may duplicate parts of schema.sql; verify it's just reading from the canonical file, not encoding its own shape.
