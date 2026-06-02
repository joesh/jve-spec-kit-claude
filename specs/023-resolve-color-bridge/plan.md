# Implementation Plan: JVE ⇄ DaVinci Resolve Color Roundtrip Bridge

**Branch**: `023-resolve-color-bridge` (cut at /implement) | **Date**: 2026-05-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/023-resolve-color-bridge/spec.md`

## Summary

Send a JVE cut to DaVinci Resolve Studio, grade it there, and bring the grade back into JVE. A persistent helper process owns the Resolve scripting connection; JVE spawns/supervises it (QProcess) and talks to it over a Unix domain socket with line-delimited JSON. JVE gains its first export path (a `.drt` writer mirroring the existing DRP binary *decoder*), a new persisted color model (CDL + LUT-ref per clip, read-only, displayed via a renderer CDL stage), and a persisted identity ledger that survives JVE re-edits so re-conform doesn't scramble grades. Grade read-back is asymmetric and honest: primary CDL syncs live; complex node graphs are flagged and only fully realized via a Resolve render that JVE relinks to. Identity is **bidirectional, two channels** (corrected by 2026-05-29 inbound spike T047, see spec §"Session 2026-05-29"): **file↔file** uses the DRP-persisted `Sm2Ti DbId` adopted on import as `clip.id` (mirrors `media.id`); **live API** uses a clip marker holding `clip.id` (`TimelineItem:AddMarker`/`GetMarkers`). DRP `DbId` does NOT bridge to the live scripting API (proven 0/1003). Outbound DRT carries `clip.id` via both carriers (DbId for the next file↔file import + marker for live read-back). First-connect of an already-imported project uses positional/content match (`name + record-TC + source-TC + media identity`) until a user-consented marker stamp pass converts to id-anchored sync. Beyond grades, JVE can pull **Resolve-side edit tweaks** (record/source/track/enabled) back via an explicit, undoable, conflict-aware command (JVE stays the edit authority of record). Topology is same-machine; one Resolve target per JVE project; grades read-only; manual sync; deletion cascades with stale-flagging.

The detailed engineering design lives in [research.md](./research.md) (architecture, wire protocol internals, DRT-writer format notes, phased de-risk plan with STOP gates). This plan is the bridge from spec → tasks.

## Technical Context

**Language/Version**: LuaJIT 2.1 (JVE model/command/UI/exporter layers + **all bridge policy**: supervision, protocol, correlation); C++17 / Qt6 only for **thin one-to-one FFI** (`qt_process_*`, `qt_local_socket_*`, `qt_zstd_compress`) and the renderer CDL stage. No Resolve-specific or supervision logic in C++ (ENGINEERING 2.18 FFI≠business-logic, 1.10 stay-in-layer). Helper process: **Python** (resolved by the Phase-0 spike, `phase0-findings.md`: external LuaJIT segfaults loading `fusionscript.so`'s `luaopen_dfscript`; Python connects to Studio 20.3.2.9 cleanly) — invisible to JVE behind the socket.
**Primary Dependencies**: Qt6 (Network — `QLocalSocket` client + `QProcess`, already linked per spec 020; existing `debug_terminal` is the server-side pattern to mirror), SQLite via lsqlite3, libzstd (existing `qt_zstd_decompress`; add `qt_zstd_compress`), dkjson (wire JSON), DaVinci Resolve Studio scripting API (`fusionscript` — **helper process only**, never linked into JVE).
**Storage**: SQLite `.jvp` project files. Schema **V11 → V12**: new `clip_grade` and `resolve_bridge_link` (incl. `edit_fingerprint`) tables (no migration — Joe regenerates). `clip.id` may now be a Resolve **`Sm2Ti DbId`** (adopted on DRP import, mirroring `media.id`); no schema change for that — `clips.id` is already `TEXT`. (The DbId is durable for file↔file re-conform only; live-API identity is the clip marker per spec FR-002 + spec §"Session 2026-05-29".) Helper holds a process-local idempotency ledger only (not in `.jvp`).
**Testing**: LuaJIT black-box test harness (`tests/`); `--test` mode (`jve --test`) for binding/integration tests needing real Qt/EMP; DRT-writer round-trip against JVE's own importer (`drp_importer.parse_drp_file`); **live tests against a real Resolve Studio**; pixel-compare for CDL math. No mocks that assert their own canned values (constitution III, `feedback_no_mocks_use_test_mode`).
**Target Platform**: macOS (darwin); Unix domain socket transport.
**Project Type**: single desktop app (JVE) + one sidecar helper process.
**Performance Goals**: renderer CDL stage applies within the existing park/60 Hz playback budget; no per-frame allocation (`feedback_malloc_cost`). Manual sync is interactive (not latency-critical).
**Constraints**: Resolve **Studio required** (no free-tier fallback); **same-machine** topology (local media/LUT/render paths); importers/DRT-writer **must not probe media** (`feedback_importers_no_media_probe`); model mutation **only via command system** (`todo_command_bypass_enforcement`); timecode-is-truth, absolute TC in the DRT (`feedback_timecode_is_truth`); fail-fast asserts, no fallbacks.
**Scale/Scope**: typical edit timelines (hundreds–low-thousands of clips per sequence); single user; single active Resolve target per project.

## Constitution Check
*GATE: must pass before Phase 0. Re-checked after Phase 1 design. (Principles from `.specify/memory/constitution.md` v2.0.0 — the stock template defaults were replaced.)*

- **I. Modular Architecture / MVC**: ✅ Resolve access quarantined in a standalone helper process; JVE client is a self-contained `core/resolve_bridge/` module. Grade display is pull-based — the renderer reads grade from model state (FR-016), never an imperative push.
- **II. Command-Driven Interface**: ✅ All user operations are commands: `SendToResolve`, `SyncGradesFromResolve`, `QueueResolveRender`. Grade sync is undoable.
- **III. Test-First (NON-NEGOTIABLE)**: ✅ DRT-writer gets reader-round-trip tests first; identity join + grade math get live/pixel tests first; each STOP-gate phase is test-gated. No assumption-encoding mocks.
- **IV. Documentation-Driven**: ✅ spec.md + research.md precede implementation; clarifications locked.
- **V. Template-Based Consistency**: ✅ this plan + data-model + contracts + quickstart follow the speckit templates.
- **VI. Fail-Fast**: ✅ dead Resolve handle, helper-start failure, locale fractional-rate corruption, missing identity field → loud structured errors / asserts, never silent recovery.
- **VII. No Fallbacks**: ✅ no `or 0`/default grades; unrelinked media is reported, not silently skipped; missing read-back fields assert.
- **VIII. No Backward Compat**: ✅ schema bumps V12 with no migration; no shims.

**Gate result: PASS.** Justified deviations recorded in Complexity Tracking (separate process; possibly non-Lua helper; reverse-engineered DRT format).

## Project Structure

### Documentation (this feature)
```
specs/023-resolve-color-bridge/
├── plan.md              # This file
├── spec.md              # WHAT/WHY + clarifications
├── research.md          # Engineering design + phased de-risk (Phase 0 output, already authored)
├── data-model.md        # Phase 1 — entities, schema V12, validation, lifecycle
├── quickstart.md        # Phase 1 — acceptance-scenario walkthrough against real Resolve
├── contracts/
│   └── helper-protocol.md   # Phase 1 — the JVE⇄helper wire contract (verbs, envelope, errors)
└── tasks.md             # Phase 2 (/tasks — NOT created here)
```

### Source Code (repository root)
```
src/
  lua/
    importers/
      drp_importer.lua          # MODIFIED — capture Sm2TiVideoClip/AudioClip DbId (FR-011b)
      importer_core.lua         # MODIFIED — pass adopted DbId as clip.id (mirror media.id) (FR-011b)
    exporters/
      drt_writer.lua            # NEW — authors a .drt from a JVE sequence (FR-001..004)
      drt_binary.lua            # NEW — encoder mirror of importers/drp_binary.lua decoders
    models/
      clip_grade.lua            # NEW — per-clip CDL/LUT/fidelity/stale model (FR-014)
    core/
      resolve_bridge/
        client.lua              # NEW — request/response over the socket, correlation ids
        protocol.lua            # NEW — envelope build/parse, structured errors (contracts/)
        helper_supervisor.lua   # NEW — lifecycle POLICY in Lua (start/restart/timeout) over the thin FFI (FR-007)
        identity_ledger.lua     # NEW — resolve_bridge_link read/write, id + positional match, reconcile (FR-011..013a)
        edit_diff.lua           # NEW — diff live edit state vs JVE clip + edit_fingerprint; classify Resolve-change vs local-change (FR-025)
        change_token.lua        # NEW — {sequence_id, mutation_generation}(+project id) token (FR-008)
      commands/
        send_to_resolve.lua            # NEW — author DRT + import_timeline + record mapping
        connect_to_resolve_project.lua # NEW — connect an imported jvp: id match + positional fallback (FR-011c)
        sync_grades_from_resolve.lua   # NEW — read_grades + upsert clip_grade (undoable, FR-017)
        sync_edits_from_resolve.lua    # NEW — read_timeline + apply edit deltas, conflict-aware (undoable, FR-024/025)
        queue_resolve_render.lua       # NEW — queue_render + poll + relink (FR-018/019)
    schema.sql                  # MODIFIED — V12: clip_grade, resolve_bridge_link (+ edit_fingerprint)
  qt_bindings/
    zstd_bindings.cpp           # MODIFIED — add qt_zstd_compress (mirror qt_zstd_decompress)
    process_bindings.cpp        # NEW — thin QProcess FFI (qt_process_start/terminate/state); generic, not Resolve-specific
    local_socket_bindings.cpp   # NEW — thin QLocalSocket client FFI (qt_local_socket_connect/write + readyRead signal)
  editor_media_platform/        # MODIFIED — renderer CDL stage (per-pixel slope/offset/power+sat, then LUT)
tools/
  resolve-helper/               # NEW — the sidecar process (Python, resolved by Phase 0)
    helper main + Resolve-API adapter (import/read_identities/read_grades/queue_render/render_status)
tests/
  test_drt_writer_roundtrip.lua            # NEW — encode→decode equality via existing reader
  test_clip_grade_model.lua                # NEW — CDL store/load, fidelity, stale, cascade
  test_sync_grades_command.lua             # NEW — execute/undo restores prior grade
  integration/
    test_resolve_bridge_socket.lua         # NEW (--test) — client↔helper envelope round-trip
  live/                                    # NEW — gated live-Resolve tests (identity join, grade read-back, idempotency, render)
```

**Structure Decision**: single JVE project (the existing `src/lua` + `src/` C++ tree) plus one sidecar under `tools/resolve-helper/`. The JVE-side bridge code is a cohesive `core/resolve_bridge/` module; **all bridge policy lives in Lua**. The C++ touch is minimal and **generic** — thin QProcess/QLocalSocket FFI (reusable, not Resolve-aware), one zstd function, and the renderer CDL stage. No Resolve-specific code crosses into C++, which both satisfies ENGINEERING 2.18 (FFI = one-to-one Qt, no business logic) / 1.10 (stay in layer) and reinforces the spec's isolation goal. This matches existing conventions (`importers/`, `core/commands/`, `qt_bindings/`). Naming note: `resolve_bridge` refers to the DaVinci Resolve *app* integration (consistent with existing `import_resolve_project.lua`, `resolve_database_importer.lua`); `feedback_no_resolve_word` bans "resolve" as a *verb* in code names, not the app noun.

## Phase 0: Outline & Research — COMPLETE

Captured in [research.md](./research.md). No `NEEDS CLARIFICATION` markers remain (the five clarifications are locked in spec.md; two items are explicitly deferred to de-risk Phases 2 and 4, not unknowns blocking design). Key decisions with rationale:

- **Decision: persistent helper process owning the Resolve handle.** Rationale: roundtrip is a conversation; amortizes connect; isolates BMD API drift + crashes. Alternatives rejected: per-op `fuscript` shelling (re-runs fragile connect + locale landmine every call); in-process `fusionscript` (undocumented ABI, forbidden).
- **Decision: author native `.drt`** (Joe-locked) using the existing decoder as the format oracle. Alternatives rejected: FCP7 XML (lower fidelity into Resolve), AAF/EDL (weak identity carriage).
- **Decision: build a JVE color model** (schema V12) — required because JVE has no color anything today; read-back has nowhere to land otherwise.
- **Decision: identity ledger in `.jvp`**, not in the helper. Rationale: must survive JVE re-edits + reconcile new clip UUIDs; helper owning it would create a second source of truth.
- **UNVERIFIED → spikes (research.md §10):** external-Lua connectivity (Phase 0), the identity field that survives DRT import (Phase 1), handle staleness on project switch (Phase 0), minimal DRT Resolve will import (Phase 1), CDL math convention (Phase 3, pixel-compare).

## Phase 1: Design & Contracts — COMPLETE

Outputs generated in `$SPECS_DIR`:

1. **`data-model.md`** — `clip_grade` and `resolve_bridge_link` (schema V12), field types, validation rules (fidelity enum, CDL nullability, stale semantics), lifecycle (sync upsert, FK cascade on clip delete, stale-on-missing-item), and the in-flight identity-ledger reconcile rules.
2. **`contracts/helper-protocol.md`** — the JVE⇄helper wire contract: versioned envelope, the six verbs (`ping`, `import_timeline`, `read_identities`, `read_grades`, `queue_render`, `render_status`), result/error shapes, idempotency on the change token, per-verb handle revalidation, locale-rate guard. This is the testable boundary (contract tests assert request/response shape; live tests assert observable Resolve state).
3. **`quickstart.md`** — the seven acceptance scenarios as an executable walkthrough against a real Resolve Studio (send → verify N items + join key → grade → sync → display/pixel-check → blade+re-send → render+relink), plus the idempotency double-send check.

**Agent context**: ran `.specify/scripts/bash/update-agent-context.sh claude` — registered the new tech (Resolve bridge, DRT export, color model) in `CLAUDE.md` for future sessions.

**Post-Design Constitution re-check: PASS.** No new violations; design keeps Resolve code isolated, mutation command-routed, display pull-based.

## Phase 2: Task Planning Approach
*Description only — `/tasks` produces tasks.md; do not create it here.*

**Strategy** — tasks follow the research.md STOP-gated phases, each gate test-first:
- **Spikes first (no production code):** Phase-0 connection spike, Phase-1 identity+minimal-DRT spike. Each emits a findings note; a contradicted assumption STOPs for report (constitution VI; spec §0).
- **Contract → contract test [P]** per verb in `helper-protocol.md`.
- **Entity → model task [P]:** `clip_grade`, `resolve_bridge_link` + `schema.sql` V12; model tests first (store/load/cascade/stale).
- **DRT writer:** `drt_binary.lua` encoders mirroring each decoder, each with a decode∘encode round-trip test BEFORE Resolve sees a file; then full-file importer round-trip.
- **User story → integration/live test:** each acceptance scenario in quickstart.md becomes a gated live test.
- **Implementation tasks** make the failing tests pass, in dependency order: schema/model → DRT writer → thin QProcess/QLocalSocket FFI → Lua helper-supervisor + socket client → `SendToResolve` → renderer CDL stage + `SyncGradesFromResolve` → identity reconcile → render + relink.

**Ordering**: TDD throughout; models before commands before UI; helper-protocol contract tests before helper impl; mark [P] for independent files. Branch is cut at the start of /implement (`start-feature-branch.sh`).

**Estimated Output**: ~30–40 tasks (larger than the template's 25–30 default because this feature spans a new exporter, a new color model + renderer stage, a sidecar process, and a live-Resolve test suite). `/tasks` will note any coverage it bounds.

## Complexity Tracking
*Justified deviations from the simplest possible design.*

| Deviation | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| Separate helper process (not in-JVE) | Quarantine BMD API drift + crashes; the scripting bridge is external | In-process `fusionscript` has an undocumented ABI and is forbidden; per-op shelling re-runs the fragile connect + locale landmine every call |
| Helper is Python, not Lua (resolved by Phase 0) | External LuaJIT segfaults loading `fusionscript.so` (PUC-Lua-5.1 ABI vs LuaJIT); Python connects cleanly — `phase0-findings.md` | Forcing Lua would need a separate PUC Lua 5.1 runtime JVE doesn't have, and the module still crashes under LuaJIT; language is invisible to JVE behind the socket, so the cost is contained |
| New color model + renderer CDL stage | JVE has zero color model; read-back grades have nowhere to land or display | "Render-and-relink only" was offered and Joe chose store+display, so the model is required, not optional |
| Reverse-engineered `.drt` writer | No exporter exists; Joe chose native `.drt` for fidelity | FCP7 XML (which JVE already parses) is lower-fidelity into Resolve; round-trip against the existing reader mitigates the format risk |
| First `QProcess` in the codebase (thin FFI; policy in Lua) | JVE must own helper lifecycle for predictable UX | External/manual helper launch shifts setup burden to the user and loses crash-restart |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (research.md authored + decisions locked)
- [x] Phase 1: Design complete (data-model.md, contracts/, quickstart.md, agent context)
- [x] Phase 2: Task planning approach described (tasks.md NOT created)
- [x] Phase 3: Tasks generated (/tasks — tasks.md, 45 tasks, STOP-gated)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved (5 clarifications locked; 2 items deferred to de-risk phases by design)
- [x] Complexity deviations documented

---
*Based on Constitution v2.0.0 — `.specify/memory/constitution.md`*
