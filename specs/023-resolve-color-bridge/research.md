# 023 — JVE ⇄ DaVinci Resolve Color Roundtrip Bridge

**Target executor:** Claude Code (any session)
**Status:** spec — no implementation yet. Phased, STOP-gated (see §10).
**Scope:** the *live* roundtrip — JVE authors a `.drt`, a persistent helper process drives a running **Resolve Studio** over the external scripting bridge, grades are read back into a **new JVE color model** and displayed in JVE's viewer; rendering graded masters is a later phase.
**Out of scope (designed-for, not built here):** the free-tier in-Resolve-script path; full node-graph color fidelity (power windows, secondaries, multi-node trees — only CDL + LUT-ref survive read-back); linking `fusionscript` into JVE's C++ process (forbidden — §4).

> This spec supersedes the generic `jve-resolve-bridge-spec.md` draft. That draft was sound on transport and discipline but made three claims about JVE that are **false** (see §1.1). This version is grounded in JVE's actual code.

---

## 0. Rules of engagement (read first — applies to every phase)

These exist because work on this codebase has failed in specific, recurring ways. Follow them literally. The first six are the original draft's; the rest are JVE-house rules that bite this feature directly.

1. **`UNVERIFIED` assumptions get a spike, not implementation code.** Every `UNVERIFIED` tag below is paired with a spike. Run it against a real running Resolve Studio and report the *actual* behavior before building on it.
2. **If a spike contradicts this spec, STOP and report.** Do not invent a silent workaround. The spec being wrong is expected and useful; a workaround that hides a wrong assumption is the worst outcome.
3. **No test passes by construction.** A test that mocks the Resolve API and asserts the mock returned its own canned value proves nothing and is prohibited (§9). JVE house rule already forbids mocks that encode assumptions — this is the same rule.
4. **"Done" = an observable fact occurred**, not "the function returned without raising." Acceptance criteria are observable facts. Verify the fact.
5. **Report real output.** Paste actual API return values / actual socket traffic / actual Resolve timeline state, not a paraphrase of what you expected.
6. At each **STOP gate**: summarize what was proven, what was disproven, what is now known that wasn't, and the open questions. Then wait.
7. **Importers must not probe media — and neither must the DRT writer or the helper read JVE state it wasn't handed.** JVE's standing rule (`feedback_importers_no_media_probe`): conform/relink code reads only from the project bytes. The helper holds **no** model of JVE's timeline (§4).
8. **The command system is the only model-mutation path.** Grades read back from Resolve land via a real command (`SyncGradesFromResolve`, §5.3), not a direct `Clip:save()`. Direct model writes outside a `command_event` silently corrupt the timeline cache (`todo_command_bypass_enforcement`).
9. **Timecode is the source of truth.** `source_in = tc_origin + zero-based file index`. The DRT writer must emit absolute TC, never file-relative offsets (`feedback_timecode_is_truth`). The locale fractional-rate landmine (§8) is a direct threat to this.
10. **Fail-fast, no fallbacks.** No `or 0`, no invented defaults, no silent reconnect-and-pretend. A dead Resolve handle is a structured error, not a guess (ENGINEERING.md 1.14 / 2.13).
11. **Bump schema freely** — V11→V12 goes straight into `src/lua/schema.sql`; Joe regenerates the `.jvp`. No ALTER/backfill migration (`feedback_schema_bump_freely`).

---

## 1. Architecture

**A persistent helper process owns the Resolve connection. JVE talks to the helper over a local socket. JVE never touches Resolve directly.**

```
  JVE (C++/Qt6/Lua)  <-- Unix socket, line-delimited JSON -->  helper process  <-- fusionscript bridge -->  running Resolve Studio
```

Why this shape (unchanged from the original draft — it was right):

- **Persistent helper, not per-op `fuscript` shelling.** A roundtrip is a conversation (import → verify relink → read identities → read grades → queue render → poll). The persistent process amortizes connect/acquire and keeps handles warm; per-op shelling re-runs the fragile connect path (and the locale landmine, §8) every call.
- **The helper is the only code that touches Resolve's scripting surface.** BMD changes that surface without notice (UIManager removed from the free tier in 19.1, no changelog). Quarantine all Resolve-specific code in one small, restartable, version-swappable process. Crash isolation is a bonus.
- **The helper holds the Resolve handle and an idempotency ledger (§4.3) — nothing else about JVE.** The moment it caches JVE timeline state it becomes a second source of truth that desyncs. JVE owns all orchestration and state.
- **JVE spawns and supervises the helper via `QProcess`** (decided). JVE owns the lifecycle: start on first roundtrip use, restart on crash, kill on quit; then connect as a `QLocalSocket` client. The C++ side is **thin one-to-one FFI only** (`qt_process_*`, `qt_local_socket_*`) — generic, not Resolve-aware; the lifecycle *policy* (when to restart, the connect-timeout, reconnect) lives in Lua (`core/resolve_bridge/helper_supervisor.lua`), per ENGINEERING 2.18 (FFI ≠ business logic) and 1.10 (stay in layer). This keeps JVE's first `QProcess` use as reusable plumbing and all bridge behavior testable in Lua. The helper writes its socket path to a known app-support location on startup; the Lua supervisor waits for it with a structured timeout error, never a silent retry-forever.
- **Helper language: Lua if Phase 0 proves Lua-external works on the target Studio** (preferred — matches JVE's stack, and the same Resolve-side logic is reusable by the future free in-Resolve path). Fall back to Python only if Lua cannot make an external connection. JVE is unaffected either way — it only sees the socket.

### 1.1 What the original draft got wrong about JVE (corrected here)

| Original draft claim | JVE reality (verified in code) | Consequence for this spec |
|---|---|---|
| "JVE already has a `.drp`/`.drt` converter; the helper just imports it." | JVE has DRP/DRT/FCP7/prproj **importers only** (`src/lua/importers/`). **Zero export.** No XML/zip authoring anywhere. | **Authoring a `.drt` is net-new, hard work** — a whole phase (§6). It is *the* first hard problem, not a given. |
| "Stable GUIDs (event-sourced object registry)." | Command/undo stack mutating SQLite rows. IDs are UUIDs (`src/lua/uuid.lua`), **stable across undo/redo** (via `_id_pool`) but **freshly minted on every re-import** and on blade/split. No event-sourced projection. No project-level version GUID. | The join key (§2) works *within a project session*. The re-conform scenario needs a **persistent JVE↔Resolve identity ledger** keyed by clip UUID, because a JVE re-edit can change clip UUIDs (§2.2). |
| Color read-back returns a CDL the bridge hands to JVE. | JVE has **no color model at all** — no CDL/LUT/sat fields in schema, no color op in the renderer. | Read-back has nowhere to land until we **build a color model** (schema V12 + model + command + renderer color stage). This is §5 and a prerequisite for "display grades." |

What the draft got *right* and we keep: helper-process isolation, Unix-socket + line-delimited JSON, structured errors, idempotency ledger, asymmetric read-back honesty (`fidelity` flag), the landmines, the testing discipline, the STOP-gate cadence.

### 1.2 What JVE already has that we reuse

- **Unix socket server**: `src/debug_terminal.{h,cpp}` (`QLocalServer`/`QLocalSocket`, spec 020), launched via `--control-socket`. Qt6::Network is already linked. JVE connects to the helper as a **client** — same Qt API, opposite direction; trivial.
- **DRP/DRT binary format knowledge**: `src/lua/importers/drp_binary.lua` is a complete **decoder** library — `read_be32/64`, `decode_hex_double`, `decode_le_double_pure`, `decode_tlv_fields`, `decode_bt_video_time`, `decode_media_timemap`, `decode_fields_blob` (zstd via `qt_zstd_decompress`), `extract_media_refs`. The DRT *writer* (§6) mirrors these as **encoders**. The decoder is the writer's oracle: round-trip every blob (write → decode with the existing reader → assert equality) before Resolve ever sees the file.
- **Relink**: `media_relinker.lua` / `relink_planner.lua` / `RelinkClips` command. The render-and-relink path (later phase) reuses this wholesale to point JVE clips at Resolve-rendered graded files.
- **Stable media identity for DRP-sourced media**: `media.file_uuid` (= Resolve `MediaRef DbId`, used as `media.id`). Lets the DRT writer emit MediaRefs Resolve will relink against.
- **Command + undo infrastructure**: `command_manager.lua`. Grade sync is a command (§5.3).

---

## 2. The hard problems for JVE: authoring + identity (color is §5)

Identity is **bidirectional** — the relationship can originate on either side, and the join differs accordingly:

- **Outbound** (JVE originates the timeline): JVE authors a `.drt` carrying its `clip.id` in a field Resolve preserves and the API can read back (§2.1).
- **Inbound** (Resolve originated it; JVE imported the DRP — the common real case, e.g. "I imported a graded DRP, now connect it to the live project"): JVE never injected an id into Resolve. Instead, **on import JVE adopts the Resolve timeline-item id as its own `clip.id`** (§2.1a). Then `clip.id` *is* the Resolve id and connect is a direct lookup.

Both directions then share one reconcile path (§2.2) for clips that lack a usable id (post-import blades, pre-adoption projects). The two `UNVERIFIED` joins below gate everything downstream.

### 2.1 Outbound — the DRT must round-trip an identity field

JVE writes a `.drt`; Resolve imports it; the scripting API reads items back. We need a Resolve-side field that:

- **(a)** JVE can write into the DRT it authors,
- **(b)** Resolve **preserves through import**, and
- **(c)** the scripting API can **read back**.

That field carries JVE's `clip.id` and becomes the join key. Candidates, in rough order of preference: a dedicated clip **metadata** field; the timeline-item / clip **name**; a **marker** payload. **Which one satisfies (a)+(b)+(c) is `UNVERIFIED`** and is the single most important thing to establish. Phase 1 proves which survives by *actual read-back byte-equality*, not assumption.

### 2.1a Inbound — adopt the Resolve item id as `clip.id` on import

The DRP carries a per-timeline-item `DbId` (`Sm2TiVideoClip`/`Sm2TiAudioClip` attribute) — today the importer reads pool-item DbIds (→ `media.id`) but **drops** the timeline-item DbId. The fix mirrors the existing media rule (`importer_core.lua`: `media.id = MediaRef DbId or uuid.generate()`): **`clip.id = Sm2Ti DbId (if present) else uuid.generate()`.** A grep confirmed no code assumes `clip.id` is UUID-shaped (media.id already isn't). Benefits: connect-by-id with nothing injected into Resolve; stable ids across re-imports; V/A are distinct Resolve items → distinct ids, no collision.

> `UNVERIFIED` (gates inbound connect): does the DRP's `Sm2Ti DbId` **equal the live scripting API's `TimelineItem` unique id**? If yes → `clip.id` directly matches the live item. If no → a deterministic DbId↔unique-id translation or the §2.2 positional match is required. Same spike family as §2.1, inbound direction; Phase 1.

### 2.2 The re-conform identity ledger (JVE-specific, the draft missed this)

The draft assumed JVE GUIDs are stable forever ("event-sourced"). They are not: a re-edit in JVE that re-imports, blades, or recreates clips mints **new** clip UUIDs. So "re-conform into an already-graded Resolve timeline without scrambling existing grades" cannot rely on the clip UUID alone surviving a JVE-side edit.

Therefore JVE persists a **bridge identity ledger**: a new table mapping `(jve_clip_uuid) ↔ (resolve_item_id, last_seen_grade_fingerprint)` per export target. On re-export, JVE reconciles: clips whose UUID is unchanged keep their Resolve item; clips that were bladed/recreated are matched to prior Resolve items by **content identity** (media `file_uuid` + source TC range + timeline position), and the ledger is rewritten. The ledger lives in the `.jvp` (it is JVE state, not helper state — see §7). This is what lets JVE beat FCP7→Color, which had no stable identity at all.

**Bladed-clip rule (decided): both halves inherit the parent's grade.** When a graded JVE clip is bladed/split into two clips with new UUIDs, both new clips reconcile to the parent's prior Resolve item and inherit its grade. The colorist's work on the un-split clip is not lost; it propagates to every fragment. (If a fragment is later regraded independently in Resolve, read-back overwrites that fragment's grade only — they diverge naturally.)

> `UNVERIFIED`: the exact content-identity match used to recognize a fragment *as* a child of a prior Resolve item (candidate: `media.file_uuid` + overlapping source TC range). Phase 4 designs it against observed Resolve behavior; do not build it before Phases 1–3 prove the simpler same-UUID path.

---

## 3. The roundtrip, end to end (JVE-grounded)

1. **JVE → DRT** (§6). JVE authors a `.drt` from the active sequence, writing the proven identity field (§2.1) per clip and MediaRefs against `media.file_uuid`.
2. **Helper → Resolve.** `import_timeline` imports the DRT, relinks media against `media_roots`, reads back the identity join, returns `{ mapping, unrelinked }`. JVE records the mapping in its identity ledger (§2.2).
3. **Colorist grades in Resolve** (human step).
4. **Helper → JVE grades.** `read_grades` returns per-clip CDL and/or LUT-ref with a mandatory `fidelity` flag (§4.4).
5. **JVE stores + displays.** `SyncGradesFromResolve` command (§5.3) writes grades into the V12 color model; the renderer's color stage (§5.4) applies CDL; SequenceMonitor displays graded frames (pull-based, MVC).
6. **(Later phase) Render.** `queue_render` renders graded masters in Resolve; JVE relinks to them via the existing relink path — delivering full node-graph fidelity that CDL read-back cannot represent.

---

## 4. Constraints

- **Helper is a separate process. Do not link `fusionscript` into JVE's C++ process.** Undocumented ABI, out of scope regardless.
- **Transport is a Unix domain socket** (macOS target), path under JVE's app-support dir. Not TCP.
- **Wire format is line-delimited JSON** (one object per line, `\n`-terminated).
- **Studio required.** The external bridge isn't exposed by the free tier. Acceptable; do not add a free-tier fallback here.
- **Helper holds no JVE timeline model** — only the Resolve handle + idempotency ledger (§4.3).

### 4.1 Framing & envelope

Request: `{ "v": 1, "id": "<correlation-id>", "verb": "<verb>", "args": { ... } }`
Response: `{ "v": 1, "id": "<same id>", "ok": true, "result": {...} }` or `{ "v": 1, "id": "<same id>", "ok": false, "error": { "code": "<machine-code>", "message": "<human>" } }`

- `v` present from the first message; bump on breaking change. The future free-path script speaks the same protocol — the explicit contract is what makes that reuse safe.
- `id` is JVE's correlation id — its only job is matching a response to its request, no semantics. Idempotency keys off `args.jve_change_token` (§4.6), not `id` (§4.3).
- Errors are structured. No bare strings, no swallowing. A dead handle is an `error` with a specific code, not a crash and not a silent reconnect.

### 4.2 Verbs

| Verb | Args | Result | Notes |
|---|---|---|---|
| `ping` | — | `{ alive, resolve_connected, resolve_version, helper_version }` | Liveness + version surface to gate on. |
| `import_timeline` | `{ drt_path, media_roots[], jve_change_token }` | `{ mapping:[{jve_guid, resolve_item_id}], unrelinked:[...] }` | Imports JVE-authored DRT, relinks against `media_roots`, returns the identity join (§2.1). Idempotent on `jve_change_token` (§4.3). Reports media it could not relink rather than proceeding silently. |
| `read_identities` | — | `{ items:[{resolve_item_id, jve_guid}] }` | Current Resolve items with recovered join keys. Reconciles after manual changes in Resolve. |
| `read_grades` | `{ item_ids?:[...] }` | `{ grades:[{jve_guid, cdl?:{slope[3],offset[3],power[3],sat}, lut?:{ref}, fidelity:"primary"\|"partial"\|"unrepresentable"}] }` | Read-back is thinner than write (§4.4). `fidelity` mandatory and honest. |
| `queue_render` | `{ spec, jve_change_token }` | `{ job_id }` | Later phase. Idempotent on `jve_change_token` + spec hash. |
| `render_status` | `{ job_id }` | `{ state, progress, output_paths? }` | Pollable. |

### 4.3 Idempotency (the one piece of state the helper may hold)

A minimal ledger: per state-changing verb, the last `jve_change_token` it successfully applied plus enough to return the same `result`. A dropped reply + re-send bearing the same `jve_change_token` returns the prior result instead of re-importing/re-rendering (the `id` may be reused or fresh — it plays no part in dedup). **Deduplication, not modeling.** It must not grow into a timeline cache.

### 4.4 Color read-back is asymmetric — design around it

`SetCDL`/`SetLUT` are write setters; the API's *read* surface for grades is weaker. Realistically per clip you get a **CDL** (slope/offset/power + saturation) and/or a **baked LUT reference** — **not** an arbitrary node graph. Therefore:

- `read_grades` returns CDL and/or LUT and a mandatory `fidelity`. When the Resolve grade exceeds CDL/LUT (power windows, secondaries, multi-node), `fidelity` is `"partial"`/`"unrepresentable"` and the bridge does **not** pretend otherwise.
- Product boundary this implies (reflected in JVE UX, §5.5): **primary grade syncs live; full grade is realized only on a Resolve render.** The protocol lets JVE tell the difference per clip.

### 4.5 Handle validity

Whether a long-lived handle survives the user switching projects/timelines in Resolve's UI is `UNVERIFIED` (Phase 0). Until proven otherwise, **every verb cheaply revalidates the handle** (confirm project manager + current project reachable) and reacquires if stale, surfacing a structured error if reacquisition fails. Treat "connect once" as "connect once, revalidate per verb."

### 4.6 `jve_change_token` (replaces the draft's "timeline-version GUID")

JVE has **no project-level version GUID**. The change token is `{ sequence_id, mutation_generation }` (the per-sequence monotonic counter, `sequences.mutation_generation`, bumped once per user-visible action). It detects "did this sequence change since the helper last saw it." Caveats it must respect: not globally unique across sequences, not content-addressable, not stable across `.jvp` file copies. For the idempotency ledger that is sufficient (it dedups retries within a session). For cross-session safety, the token additionally carries the `projects.id` UUID + a content hash of the exported DRT, so a copied/restored project doesn't collide. `UNVERIFIED` whether the content hash is needed in practice — Phase 2 decides.

---

## 5. The JVE color model (NEW — prerequisite for "store + display grades")

JVE has no color anything today. This section is the largest net-new subsystem and is what makes "store and display grades" real.

### 5.1 Schema (V11 → V12, `src/lua/schema.sql`)

New table `clip_grade` (grades are per timeline item; Resolve's clip grade maps to a JVE clip):

```sql
CREATE TABLE IF NOT EXISTS clip_grade (
    clip_id        TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    -- CDL primaries; NULL when fidelity has no representable CDL
    slope_r REAL, slope_g REAL, slope_b REAL,
    offset_r REAL, offset_g REAL, offset_b REAL,
    power_r REAL, power_g REAL, power_b REAL,
    saturation REAL,
    lut_ref        TEXT,            -- local LUT path (same-machine topology), or NULL
    fidelity       TEXT NOT NULL,   -- 'primary' | 'partial' | 'unrepresentable'
    source         TEXT NOT NULL,   -- provenance, e.g. 'resolve_readback' (grades are read-only in JVE)
    stale          INTEGER NOT NULL,  -- 0/1; writer sets it explicitly (no SQL default — 2.13). 1 = source Resolve item absent at read-back
    synced_at      INTEGER NOT NULL
);
```

Plus the identity ledger (§2.2). Single Resolve target per project, so the key is the clip id alone; FK cascade drops the link when the clip is deleted:

```sql
CREATE TABLE IF NOT EXISTS resolve_bridge_link (
    jve_clip_uuid    TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    resolve_item_id  TEXT NOT NULL,
    grade_fingerprint TEXT          -- last-seen grade hash, for change detection
);
```

Bump `schema_version` to 12. No migration — Joe regenerates (§0.11).

**Decided: grade attaches to `clips.id`** (Resolve grades the timeline item; that's the read-back join). A future "source grade" (one grade shared by all uses of a media file) would key on media — deferred until asked.

### 5.2 Model layer

`src/lua/models/clip_grade.lua` — load/CRUD mirroring existing model modules (`models/clip.lua` conventions: no direct `database.get_connection()` from commands, SQL isolation policy). Provides `ClipGrade.load(clip_id)`, batch loaders for the renderer, and a `fingerprint(grade)` for §2.2 change detection.

### 5.3 Command: `SyncGradesFromResolve`

Read-back grades mutate the model **only through a command** (§0.8). New command `src/lua/core/commands/sync_grades_from_resolve.lua`:

- **execute**: given `{ grades:[{jve_guid, cdl?, lut?, fidelity}] }` from `read_grades`, upsert `clip_grade` rows for the mapped clips; update `resolve_bridge_link.grade_fingerprint`.
- **undo**: restore prior `clip_grade` rows (capture before-state in the command, standard JVE undoer pattern — study `paste.lua` execute+undoer before writing this, per `feedback_no_lazy_shortcuts`).
- Bumps `mutation_generation` like any sequence-scoped command.
- Emits a signal so the inspector + viewer re-pull (MVC).

**Decided: grade-sync is undoable** — a bad read-back must be reversible. The undoer captures and restores prior `clip_grade` rows (standard JVE undoer pattern; study `paste.lua` execute+undoer before writing it, per `feedback_no_lazy_shortcuts`).

### 5.4 Renderer color stage (C++)

CDL is a per-pixel op → belongs in the renderer, GPU shader (CLAUDE.md: C++ for performance-critical rendering; `feedback_malloc_cost` — no per-frame allocation). The renderer **pulls** each clip's grade from the model (MVC; renderer is not a model writer — `feedback_renderer_not_media_status_writer`) and applies, per channel: `out = (in * slope + offset) ^ power`, then saturation against Rec.709 luma. LUT-ref application (3D LUT sampling) is a second, optional stage. Park mode pulls; the 60Hz hot path may push the grade alongside the frame.

`UNVERIFIED`: exact CDL math conventions Resolve uses (working color space, whether sat is pre/post CDL, clamping). Phase 3 pins this by applying a *known* CDL in Resolve, reading it back, rendering the same clip in JVE, and comparing pixels — not by reading a CDL spec and assuming.

### 5.5 UX (stated for contract honesty; full UI is its own spec)

- Inspector shows the clip's grade summary + `fidelity` badge. `partial`/`unrepresentable` clips display a "full grade requires Resolve render" affordance (§4.4).
- The viewer shows the live primary grade; it never silently claims node-graph fidelity it doesn't have.

---

## 6. The DRT writer (NEW — the export the draft assumed already existed)

JVE cannot author any interchange today. This builds a `.drt` writer. Joe chose `.drt` (Resolve-native) over FCP7 XML for fidelity; the cost is authoring Resolve's zip-of-binary-blobs format.

### 6.1 Format (from JVE's existing reader)

A `.drt`/`.drp` is a **ZIP** (`drp_importer.lua:91` unzips it) containing `project.xml`, `MediaPool/Master/**/MpFolder.xml`, `SeqContainer/*.xml`, with binary fields: BE32-framed `FieldsBlob` (`[BE32 version][BE32 size][0x81][zstd frame]`), TLV `BtVideoInfo`/`BtAudioInfo`, `MediaTimemapBA`, `EffectFiltersBA`, hex LE-doubles, `|hex` sub-frame suffixes.

### 6.2 The writer mirrors `drp_binary.lua`'s decoders

`drp_binary.lua` is pure decoders. Build `src/lua/exporters/drt_binary.lua` as the **encoder mirror** — `write_be32/64`, `encode_hex_double`, `encode_le_double`, `encode_tlv_fields`, `encode_bt_video_time`, `encode_media_timemap`, `encode_fields_blob` (zstd via a new `qt_zstd_compress` C++ binding mirroring the existing `qt_zstd_decompress`). **DRY rule (`feedback_lift_dry`):** keep encode/decode side by side; do not fork format constants.

**Oracle round-trip (mandatory, gates Resolve ever seeing the file):** for every blob, `decode(encode(x)) == x` using the *existing reader*. Then full-file: `drp_importer.parse_drp_file(written.drt)` must read back the timeline JVE intended. Only then test against real Resolve.

### 6.3 Minimal-viable DRT first

`UNVERIFIED`: how much of the format Resolve actually requires to import a timeline. The decode-everything reader proves what Resolve *writes*; it does not prove what Resolve *needs to read*. Phase 1 authors the **smallest** DRT Resolve will import (likely: project.xml + one SeqContainer + MediaRefs + the identity field) and grows it only as Resolve rejects pieces. Do not pre-build FieldsBlob/Timemap encoders before proving they're required for import.

### 6.4 What the writer emits per clip

Timeline position (`<Start>` + `|hex` subframe), `<Duration>`, source in (`<In>` + subframe — absolute TC, §0.9), `<MediaRef>` = `media.file_uuid`, `<MediaStartTime>` (file TC origin), `<MediaFrameRate>`, and the **proven identity field** (§2.1) carrying `clip.id`. Speed/volume (Timemap/EffectFilters) only if Phase 1 shows Resolve requires them for a clean import.

---

## 7. State ownership (who holds what)

- **JVE (`.jvp`)**: timeline, the V12 color model (§5.1), and the **identity ledger** (`resolve_bridge_link`). The ledger is JVE state because it must survive JVE re-edits and reconcile new clip UUIDs (§2.2) — the helper cannot own it without becoming a second source of truth.
- **Helper**: the Resolve handle + the idempotency ledger (§4.3) only. No timeline model.
- **Resolve**: the authoritative grades until read back.

---

## 8. Known landmines (do not rediscover the hard way)

- **Locale fractional frame-rate bug.** Non-US locale decimal settings have made the API report fractional rates as integers (23.976 → 23), silently corrupting conform/TC math — a direct hit on §0.9. Read the rate, sanity-check against expected fractional rates, **fail loudly** if an integer rate appears where fractional is expected.
- **Handle staleness on project switch** — §4.5.
- **API drift across Resolve versions** — *why* the helper is isolated. `ping` returns `resolve_version`; log it; re-run the relevant acceptance check rather than assuming verb behavior is stable.
- **DRT format is reverse-engineered.** The reader was built from observed Resolve output; the writer must not assume undocumented fields are optional. §6.3's grow-from-minimal discipline is the guard.
- **CDL math convention mismatch** — §5.4. Pixel-compare against Resolve; never assume the formula.

---

## 9. Testing discipline (specific to this integration)

The thing under test is an external app + a reverse-engineered file format. Mocking either and asserting the mock works is worthless (§0.3; JVE's no-mocks rule, `feedback_no_mocks_use_test_mode`).

- **DRT writer tests** run in JVE's harness and assert the **existing reader** reads back what the writer wrote (§6.2) — black-box, domain-derived expected values (`feedback_tests_from_domain`): "a clip at TC 01:00:04:12 spanning 3s round-trips to the same TC and duration," never "encode_tlv returned bytes X."
- **Live Resolve tests** run against a real running Resolve Studio and assert **observable Resolve state**: "after `import_timeline`, the Resolve timeline contains N items and item K carries join key = the JVE GUID we wrote." Driven via `--test` mode / the helper, never via mocks. (`feedback_test_with_editor`.)
- **The identity join (§2.1) gets a dedicated live test** and gates everything downstream: author a DRT with a known clip UUID in the candidate field, import via the helper, read it back, assert **byte-equality**.
- **The grade math (§5.4) gets a pixel test**: apply a known CDL in Resolve, read it back, render the clip in JVE, compare pixels within tolerance. This is the only honest proof the math matches.
- **Idempotency live test**: send the same state-changing `id` twice; assert Resolve state changed exactly once and both responses are identical.
- **Where Resolve can't be in CI**: record *real* API responses once from a real Resolve, commit as fixtures, replay — and the recording must be **regenerable** by a committed script against a real Resolve. Hand-authored shape-fixtures are forbidden (they test the author's assumptions).
- **Forbidden**: any test whose assertion is satisfied solely by its own setup.

---

## 10. De-risk order (phased, STOP-gated)

Each phase is small and ends at a STOP gate. Do not pass a gate without reporting (§0.6). Ordering differs from the draft because JVE's hard problems (authoring, identity, no color model) come *first*.

**Phase 0 — Connection spike.** Prove a standalone process makes an *external* connection to running Resolve Studio. Establish: (a) Lua-external vs Python helper; (b) does the handle survive a project/timeline switch, or is per-verb revalidation required (§4.5)? *Deliverable:* findings doc with real connection code + real `ping`-equivalent output. **No helper code yet. STOP.**

**Phase 1 — DRT authoring + identity spike (combined — they're entangled).** Build the minimal-viable DRT writer (§6.3); for each candidate identity field (§2.1) author a DRT carrying a known clip UUID, import it, read it back via the API, report which field round-trips byte-clean. *Deliverable:* the chosen join field + the minimal DRT that Resolve imports, both proven with real read-back. **STOP.**

**Phase 2 — Helper skeleton + protocol core.** Helper (Lua if Phase 0 allows, else Python), socket, envelope (§4.1), `ping`, `import_timeline` returning the identity mapping via the Phase-1 field. JVE-side: thin `qt_process_*`/`qt_local_socket_*` FFI + the Lua `helper_supervisor` (spawn/restart/timeout policy) + the Lua socket client (mirror `debug_terminal`'s plumbing, opposite direction) + write the mapping into `resolve_bridge_link`. Helper-startup failure and connect timeout surface as structured errors, never silent retry (§0.10). Live tests per §9. **STOP.**

**Phase 3 — JVE color model + grade read-back.** Build §5 (schema V12, `clip_grade` model, `SyncGradesFromResolve` command, renderer CDL stage). Implement `read_grades`/`read_identities` with honest `fidelity` (§4.4). Live tests: apply a known primary CDL in Resolve → read back → assert values → **pixel-compare** JVE render (§5.4); apply a node-graph grade → assert `fidelity` correctly downgraded. **STOP.**

**Phase 4 — Re-conform identity ledger.** Build the §2.2 reconciliation (re-edit in JVE → re-export → grades stay on the right clips, including bladed/recreated clips). Live test: grade in Resolve, re-edit in JVE, re-import, assert no grade scrambling. **STOP.**

**Phase 5 — Render (full-fidelity path).** `queue_render` + `render_status`, idempotent (§4.3); JVE relinks to rendered masters via the existing relink path (§1.2). Live test: queue → poll to completion → assert output file exists → JVE relinks and plays the graded master. **STOP.**

---

## 11. Definition of done

- Phases 0–5 complete, each STOP gate reported and reviewed.
- Helper is a separate process; JVE links no Resolve code (§4).
- All `UNVERIFIED` items proven or reported-as-disproven with the spec corrected.
- DRT writer's encoders all pass decode∘encode round-trip against the existing reader (§6.2); zero format constants forked.
- JVE color model lands (schema V12, `clip_grade`, `SyncGradesFromResolve`, renderer CDL stage); grades store, display, and undo.
- Every acceptance test asserts observable Resolve state, a regenerable real fixture, or a reader-round-trip (§9); zero pass-by-construction tests.
- `ping` reports `resolve_version`; locale frame-rate guard present and tested.

---

## Decisions locked

- **Helper lifecycle**: JVE spawns + supervises via new `QProcess` code; connects as `QLocalSocket` client (§1).
- **`SyncGradesFromResolve`**: undoable (§5.3).
- **Grade attaches to `clip.id`** (§5.1).
- **Bladed clips**: both halves inherit the parent's grade (§2.2).
- **Helper language**: Lua if Phase 0 proves Lua-external works on the target Studio; else Python (§1).

## Open questions (concise)

- `jve_change_token` (§4.6): is the DRT content hash needed, or does `{sequence_id, mutation_generation}` + `project.id` suffice for cross-session idempotency? **Joe undecided — leave to Phase 2, which has real socket traffic to judge against.**
- Bladed-fragment *recognition* (§2.2): the grade-inheritance behavior is decided; the content-identity match that identifies a fragment as a child of a prior Resolve item (candidate: `file_uuid` + overlapping source TC range) is designed in Phase 4 against observed Resolve behavior.
