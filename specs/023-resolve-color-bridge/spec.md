# Feature Specification: JVE ⇄ DaVinci Resolve Color Roundtrip Bridge

**Feature Branch**: `023-resolve-color-bridge` (cut at /implement time, not now)
**Created**: 2026-05-29
**Status**: Draft
**Input**: User description: "JVE ⇄ DaVinci Resolve color roundtrip bridge — send a JVE cut to Resolve Studio, grade it there, bring the grade back into JVE."

> Companion docs in this folder: `research.md` holds the grounded engineering design (architecture, wire protocol, DRT-writer internals, color-model schema, phased de-risk plan) and is the source for `/plan`. This `spec.md` is the WHAT/WHY: user value, testable requirements, locked decisions.

---

## Clarifications

### Session 2026-05-29

- Q: Deployment topology for v1? → A: Same machine — JVE and Resolve Studio run on one box; media, LUT, and render paths are a shared local filesystem that resolves identically on both sides. No cross-machine asset transport in scope.
- Q: Are grades read-only in JVE, or editable in JVE too? → A: Read-only in JVE — Resolve is the sole grade authority. JVE stores + displays; never edits. Re-sync overwrites. No conflict/merge model, no grade-editing UI or commands.
- Q: One Resolve target per JVE project, or many? → A: One target — a JVE project roundtrips to exactly one Resolve project/timeline at a time. Identity link and clip grade are keyed on `jve_clip_uuid` alone (no `target_id` dimension).
- Q: Grade read-back trigger — manual or auto-poll? → A: Manual pull — the editor explicitly triggers a sync; JVE does one `read_grades` + apply per action. No background polling.
- Q: Orphan handling on deletion? → A: Cascade + flag stale — deleting a JVE clip drops its grade and identity link (FK cascade from `clips`). A JVE clip whose Resolve item is gone at read-back keeps its last-synced grade but is marked stale (not cleared, not silently current).
- Q: How does an *imported* JVE project (DRP→JVP) connect to its live Resolve project, which never received JVE ids? → A: The identity model is **bidirectional**. On DRP import JVE adopts the Resolve timeline-item id as its own `clip.id` when present (mirroring how `media.id` already adopts the Resolve `MediaRef DbId`), else mints a UUID. So for imported clips, `clip.id` **is** the Resolve id — connect is a direct lookup, no injected ids needed. Outbound (JVE-authored sequences) still embeds `clip.id` in the DRT. Clips JVE created after import (blades, UUID ids) match positionally (`media.file_uuid` + source TC + timeline position).
- Q: Should Resolve-side edit tweaks (a colorist trims/slips/moves/enables a clip) come back to JVE too, or only grades? → A: Yes — pull edit changes back as well. An explicit, undoable, reviewable command reads the live timeline and applies record/source/track/enabled deltas to the matched JVE clips. JVE remains the edit authority of record (the pull is a reconcile, not auto-sync); a clip JVE edited since the last sync surfaces as a conflict for the user to resolve rather than being silently overwritten.

### Session 2026-05-29 (inbound spike — supersedes parts of FR-002/011b/011c/013, see `inbound-findings.md`)

These were proven against live Resolve Studio 20.3.2.9; they **correct** the locked id-adoption assumption above.

- Q: Does the live scripting API's timeline-item id equal the DRP-persisted `DbId` (the premise of FR-011b adoption)? → A: **No (0/1003).** `TimelineItem:GetUniqueId()` is an undocumented runtime instance handle, different from the persisted `Sm2Ti DbId` by design; the live id is absent from the DRP. Media-pool ids diverge too. **No id bridges DRP ↔ live API.** ⇒ FR-011b's "adopt the Resolve timeline-item id as `clip.id`" does **not** enable live connect.
- Q: Then how is the durable JVE-clip ↔ Resolve-item identity carried? → A: **A clip marker carrying `clip.id`** (ASCII, in the marker name and/or `customData`). `TimelineItem:AddMarker` is per-instance, round-trips through DRP export→import (proven), and is read live via `GetMarkers`/`GetMarkerByCustomData`. This replaces id-adoption as the identity channel (FR-002 field = clip marker, spike resolved). Stamping the live project is a mutation requiring user consent; the *first* connect (clips not yet stamped) is positional.
- Q: How are grades read, given the API has `SetCDL` but no `GetCDL`? → A: **Export the timeline as EDL+CDL** (`Export(EXPORT_EDL, EXPORT_CDL)` → `*ASC_SOP`/`*ASC_SAT` per event); fidelity (FR-015) from `GetNodeGraph().GetToolsInNode()`. There is no numeric grade getter. `read_grades` is implemented via this export+parse, not a per-item call.
- Q: First-connect join key when nothing is marked yet? → A: **Content/position** — `(clip name + record-TC + source-TC + media identity)`, the NLE-standard conform key (Resolve's own ColorTrace uses reel+TC). The DRP `DbId` remains valid only for **file↔file** re-conform, not live connect.
- Note: Reading a user's clip markers out of an imported DRP for *display* is a separate importer feature (markers live in `project.xml`'s `LockableBlobMap` protobuf; marker→clip linkage RE in progress) — tracked apart from the bridge, which reads markers via the live API.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

An editor finishes a cut in JVE and wants it graded by a colorist working in DaVinci Resolve Studio. From JVE they send the cut to Resolve; Resolve receives the timeline with media correctly relinked and every clip carrying a stable identity tying it back to its JVE clip. The colorist grades. The editor pulls the grades back into JVE: simple primary grades (lift/gamma/gain-style CDL) appear live in JVE's viewer; complex grades that exceed what a CDL can express are flagged as such (the editor knows JVE's display is partial / unrepresentable for those clips). Later the editor re-edits in JVE and sends again — existing grades stay attached to the right shots rather than scrambling.

### Acceptance Scenarios

1. **Given** a JVE sequence with N clips, **When** the editor sends it to Resolve, **Then** the Resolve timeline contains N items, each carrying a recoverable identity equal to its JVE clip id, and any media that could not be relinked is reported back (not silently dropped).
2. **Given** a clip graded with a primary CDL in Resolve, **When** the editor syncs grades back, **Then** that clip's CDL (slope/offset/power + saturation) is stored in JVE and the JVE viewer displays the graded result, matching Resolve's render of the same clip within tolerance.
3. **Given** a clip graded with a node graph that exceeds CDL (power windows, secondaries, multi-node), **When** the editor syncs grades back, **Then** the clip is marked with a non-primary fidelity and JVE does not falsely claim to reproduce the full grade.
4. **Given** grades have been synced into JVE, **When** the editor undoes the sync, **Then** the prior grade state is restored.
5. **Given** a graded Resolve timeline, **When** the editor blades a graded JVE clip into two and re-sends, **Then** both halves inherit the original clip's grade.
6. **Given** the bridge sent a state-changing request whose reply was lost, **When** JVE re-sends the same request, **Then** Resolve's state changed exactly once and the second response equals the first.

### Edge Cases

- **Free (non-Studio) Resolve**: the external bridge is unavailable; the feature surfaces a clear "Resolve Studio required" error and does nothing destructive.
- **Resolve handle goes stale** (user switches project/timeline in Resolve): the next operation revalidates and either reacquires or returns a structured error — never a silent reconnect-and-pretend.
- **Non-US locale fractional frame rate** reported as an integer (23.976 → 23): detected and failed loudly rather than silently corrupting conform/timecode math.
- **Media not relinkable** in Resolve: reported per-file; the import does not proceed as if complete.
- **Re-import after manual edits in Resolve**: JVE can read current Resolve identities to reconcile.
- **Graded clip deleted in JVE**: its grade and identity link are removed with it.
- **Resolve item gone at read-back** (clip still exists in JVE): the clip retains its last-synced grade but is marked stale rather than cleared or shown as current.
- **Connect a project imported before id-adoption existed**: those clips have UUID ids, not Resolve ids, so they connect by positional/content match; ambiguous or unmatched ones are reported for the user, not silently skipped.
- **Colorist re-edited in Resolve since import** (trim/slip/move/enable): pulling edits applies the deltas to matched clips; a JVE clip also edited locally since the last sync surfaces as a conflict rather than being overwritten.

## Requirements *(mandatory)*

### Functional Requirements

**Export / conform**
- **FR-001**: JVE MUST author a Resolve-importable timeline file (`.drt`) from a JVE sequence. (No exporter exists today; this is net-new.)
- **FR-002**: The authored file MUST carry, per clip, a stable identity equal to the JVE `clip.id`, in a field that survives Resolve import and is readable via the scripting API. **Field resolved (2026-05-29 inbound spike, T047): a clip marker carrying `clip.id`** (ASCII, in marker name / `customData`). DRP-persisted `Sm2Ti DbId` carries `clip.id` for **file↔file** re-conform (T004 round-trip), but does NOT bridge to the live scripting API (`TimelineItem:GetUniqueId()` is a runtime instance handle, not the DbId — 0/1003 in spike). The live join channel is the marker.
- **FR-003**: The authored file's clip ranges MUST be expressed in absolute timecode (never file-relative offsets), consistent with JVE's timecode-is-truth invariant.
- **FR-004**: Before sending any file to Resolve, JVE MUST validate the authored file by round-tripping it through JVE's own importer and confirming the timeline reads back as intended.

**Transport / isolation**
- **FR-005**: All Resolve scripting access MUST live in a separate helper process; JVE MUST NOT link Resolve's scripting module into its own process.
- **FR-006**: JVE MUST communicate with the helper over a local (Unix domain) socket using line-delimited JSON with a versioned envelope and structured (non-string) errors.
- **FR-007**: JVE MUST spawn and supervise the helper's lifecycle (start, restart on crash, stop), then connect to it as a client; helper-start and connect failures surface as structured errors, never silent retry. Each in-flight request additionally arms a single-shot reply-timeout timer (default `REQUEST_TIMEOUT_MS` 30 s, set at `client.connect`-opts time); on expiry, the request's `on_complete` fires with a structured `resolve_api_error` — never a silent drop. Wire-level corruption (malformed response line) fails every in-flight caller with the same closed-set error and closes the socket; the supervisor's next request respawns.
- **FR-008**: State-changing operations MUST be idempotent on a JVE-supplied change token, so a retried request does not re-import.
- **FR-009**: Every operation MUST cheaply revalidate the Resolve handle and reacquire if stale, or return a structured error if it cannot.
- **FR-010**: The feature MUST require Resolve Studio and MUST NOT add a free-tier fallback.

**Identity / re-conform (bidirectional)**
- **FR-011**: JVE MUST maintain a persisted clip↔Resolve-item identity link surviving JVE re-edits. The link is bidirectional: it is established by *outbound* send (JVE records the import mapping) OR by *inbound* import (FR-011b), whichever originated the relationship. For a clip whose `clip.id` already equals its Resolve item id (FR-011b), the link collapses into the id itself and no separate mapping row is required.
- **FR-011b** (inbound identity adoption — **scope corrected by T047**): When importing a Resolve project (DRP/DRT), JVE MUST adopt the Resolve `Sm2Ti DbId` as the JVE `clip.id` when present (else mint a UUID) — mirroring `media.id` (= `MediaRef DbId`). This identity is durable for **file↔file** re-conform only (`DbId` round-trips through DRP export→import). It does **NOT** address a clip in the live scripting API: `TimelineItem:GetUniqueId()` returns a runtime instance handle, not the persisted `DbId` (2026-05-29 spike, 0/1003 match). Live-API identity is carried separately by **a clip marker holding `clip.id`** (FR-011c, T048/T049).
- **FR-011c** (connect an imported project — **rewritten by T047**): JVE MUST be able to connect an already-imported project to its live Resolve project. Match channels in priority order: (a) **clip marker** carrying `clip.id` if previously stamped; (b) **content/position** = `(clip name + record-TC + source-TC + media identity)`, the NLE-standard conform key. Unmatched clips MUST be reported, not silently skipped. First-connect (clips not yet marker-stamped) is always (b); a user-consented stamp pass converts (b) → (a) for subsequent syncs.
- **FR-012**: On re-send after a JVE re-edit, JVE MUST reconcile clips to their prior Resolve items so existing grades are not scrambled; clips bladed/split since last send MUST have both resulting halves inherit the parent clip's grade.
- **FR-013**: JVE MUST be able to read back the current Resolve timeline identities to reconcile after manual changes in Resolve.
- **FR-013a**: Deleting a JVE clip MUST remove its stored grade and identity link. A JVE clip whose Resolve item is absent at read-back MUST retain its last-synced grade marked stale, never silently cleared and never shown as current. (Storage mechanism — FK cascade — is in data-model.md.)

**Color model (store + display)**
- **FR-014**: JVE MUST store, per clip, a color grade consisting of a CDL (slope/offset/power + saturation) and/or a LUT reference, plus a fidelity classification (primary / partial / unrepresentable). Grade attaches to the JVE clip. Grades are read-only in JVE (Resolve is the sole authority); JVE provides no grade-editing UI or command, so re-sync overwrites without conflict resolution. LUT references are local filesystem paths (same-machine topology).
- **FR-015**: Reading grades back from Resolve MUST report fidelity honestly: when a Resolve grade exceeds CDL/LUT, the bridge MUST mark it partial/unrepresentable rather than approximating silently.
- **FR-016**: JVE's viewer MUST display the stored primary grade (apply CDL, then LUT if present); display MUST be pull-based from model state (MVC), not dependent on an imperative push.
- **FR-017**: Applying read-back grades MUST go through the command system (undoable), restoring prior grade state on undo. Attribution of helper rows to JVE clips MUST be JVE-side: the helper emits rows keyed on its native `resolve_item_id`, and the apply layer joins via `identity_ledger.lookup_clip_id` (populated by `ConnectToResolveProject` per FR-011c). This honors FR-021 — helper holds no JVE state — and decouples the first-sync-after-Connect from any user-consented marker stamping, which remains the FR-012 durability channel for surviving Resolve-side cuts/splits.

**Edit read-back (Resolve-side tweaks)**
- **FR-024**: JVE MUST be able to read the live Resolve timeline's per-item edit state (record start/duration, source in/out, track, enabled) and apply the deltas to the matched JVE clips (FR-011c) by composing JVE's **existing** edit commands (move/trim/enable/…) under one undo group — not a new parallel edit-mutation path. This is an explicit, reviewable user action — never automatic. JVE remains the edit authority of record; the pull is a reconcile.
- **FR-025**: A JVE clip edited locally since the last sync MUST surface as a conflict for the user to resolve (keep JVE / take Resolve), never be silently overwritten by the pull. Clips with no local change since last sync apply directly.

**Safety / honesty**
- **FR-020**: The bridge MUST detect and fail loudly on the locale fractional-frame-rate corruption rather than proceeding with a wrong rate.
- **FR-021**: The helper MUST hold no model of JVE's timeline beyond the idempotency ledger; JVE owns all orchestration and state.
- **FR-022**: Tests MUST assert observable Resolve state, a regenerable real-Resolve fixture, or a JVE-importer round-trip; no test may pass solely by its own setup (no mocks-assert-mock).

**Invocation**
- **FR-023**: All bridge actions — send-to-Resolve, connect-imported-project, sync-grades, sync-edits — MUST be user-invocable through the command system (menu / shortcut / programmatic), consistent with how every JVE operation is dispatched. No bridge action is a hidden or implicit side effect.
  - **Root cause this FR ratifies.** The reason FR-023 needs a completion contract at all is a TEST-COVERAGE root cause, not a design oversight: not a single unit / binding / integration test ever drove these commands through `command_manager.execute_interactive`. Programmatic tests passed a stub `on_complete = function() end` directly to `M.execute`, so the schema-required `on_complete` went undetected for the entire feature. Menu picks then hard-failed at the schema validator with `missing required param 'on_complete'`. The SPEC bug was downstream of the testing gap. Lesson encoded below: the regression gate drives via real UI + asserts the positive completion signal, not just "no Lua error."
  - **Completion contract.** Bridge commands are async-with-callback (helper round-trip happens off the calling thread). Because `command_manager.execute_interactive` (menu / shortcut entry point) has no callback to inject, an `on_complete` arg cannot be REQUIRED — that would gate menu dispatch behind the schema validator. Every bridge command therefore:
    - Declares `on_complete` as OPTIONAL in its SPEC with `kind = "function"`. The schema still type-checks any non-nil value (`command_schema.lua:224` validates `kind` whenever `v ~= nil` regardless of `required`); the in-execute assert mirrors with `nil-or-function`. Bad input still fails loudly (rule 1.14); nil is the explicit menu/shortcut case.
    - Routes every terminal path — success AND every structured error code AND any internal assert caught by the `register`-side `pcall` — through `core.commands.bridge_completion.notify(op_name, args, result, code, message)`. The composition with `M.register`'s pcall is load-bearing: without it, an assert in `payload_builder` / `Sequence.load` / response-shape validation escapes via pcall and the `*_completed` signal never fires.
    - `notify()` (a) emits the per-op completion signal, (b) logs the outcome (event on success, error on failure), (c) bumps a monotonic per-op counter for smoke assertions, (d) calls `args.on_complete(result, code, message)` when the caller supplied one.
  - **Per-op signals (not a tagged generic).** Mirrors the rest of `core/signals.lua` convention (`marks_changed`, `content_changed`, `project_changed` etc.) — subscribers pick exactly the op they care about, no switch-on-tag:
    - `send_to_resolve_completed(result, code, message)`
    - `connect_to_resolve_project_completed(result, code, message)`
    - `sync_grades_from_resolve_completed(result, code, message)`
    - `sync_edits_from_resolve_completed(result, code, message)`
  - **Signal asymmetry — DO NOT merge these.** Completion signals are distinct from data-mutation signals:
    - `grades_changed(sequence_id)` (already exists, fires from `SyncGradesFromResolve.apply` / `.restore`) is a MODEL-MUTATION signal. Cache subscribers (the `SequenceMonitor` clip-grade cache) want this.
    - `sync_grades_from_resolve_completed(...)` (new, fires from the async tail via `bridge_completion.notify`) is an OPERATION-FINISHED signal. Toast / dialog / smoke counter want this.
    - On success both fire (apply emits the model signal, the tail emits the completion signal). On error only `*_completed` fires (no model state changed).
  - **Regression gate.** `tests/smoke/cases/test_bridge_menu_dispatch.py` clicks each Color menu item through real OS input and asserts BOTH (a) no forbidden marker (`LUA CALLBACK ERROR`, handler failure, raw assert) lands in the suite-log slice, AND (b) `bridge_completion_count(op_name)` advanced by at least one. The counter-advance assertion catches the regression class "no log marker, but pcall silently swallowed the async tail" — which "no Lua error" alone CANNOT.
  - **Open items.** `ConnectToResolveProject` is uniform-async with the other three (helper-mediated request/response); a future revisit could make it sync-return since its round-trip is short. The uniform-async shape is currently load-bearing for keeping one supervisor pattern and one notify pattern. **A sync-return revisit touches BOTH surfaces**: the SPEC arg shape (drop `on_complete` from this command's args entirely, since callers would consume the return value) AND the regression smoke (`test_bridge_menu_dispatch.py::test_01_color_connect_to_resolve_project` would need to handle a sync-return path — counter-delta assertion would still apply, but the dispatch shape under test changes). Not a one-file change.

### Clarifications (locked decisions)

- **Roundtrip depth**: build a real JVE color model — store AND display grades. Render-and-relink (FR-018/019 in earlier drafts) was carved out 2026-06-02 as out of scope for v1 — preserved at git tag `spec023-render-relink-deferred` for future revival.
- **Export format**: author native `.drt` (over FCP7 XML / AAF / EDL), using JVE's existing DRP binary reader as the format oracle.
- **Helper lifecycle**: JVE spawns + supervises via QProcess; connects as a socket client.
- **Grade-sync**: undoable.
- **Grade attaches to**: the JVE clip.
- **Bladed clips**: both halves inherit the parent's grade.
- **Helper language**: Python — resolved by the Phase-0 spike (`phase0-findings.md`): external LuaJIT segfaults loading `fusionscript.so`, no PUC Lua 5.1 present, Python connects to Studio 20.3.2.9 cleanly. (Invisible to JVE behind the socket.)
- **Identity is bidirectional, two channels** (corrected by 2026-05-29 spike — see above): file↔file uses `Sm2Ti DbId` adopted as `clip.id` (round-trips through DRP); live-API uses a clip marker stamped with `clip.id`. Outbound DRT carries `clip.id` via both the `DbId` (for next file↔file import) and the marker (for live read-back). No JVE id is injected into Resolve beyond these two carriers.
- **Resolve edits flow back**: edit deltas (record/source/track/enabled) pull into JVE via an explicit, undoable, conflict-aware command; JVE stays the edit authority of record.

### Deferred decisions (resolved during de-risk, not blockers)

- Cross-session shape of the change token (whether a DRT content hash is needed beyond `{sequence_id, mutation_generation}` + project id) — decided in Phase 2 against real socket traffic.
- The exact content-identity match that recognizes a bladed fragment as a child of a prior Resolve item — designed in Phase 4 against observed Resolve behavior.

### Key Entities

- **Authored timeline file (`.drt`)**: JVE's export carrying clip timing (absolute TC), media references, and the per-clip identity field.
- **Clip grade**: per-clip (keyed on JVE clip id) CDL (slope/offset/power, saturation) and/or local LUT-path reference, with a fidelity classification, provenance, and a stale flag (set when the source Resolve item is gone at read-back). Read-only in JVE. Dropped by FK cascade when the clip is deleted. New persisted JVE entity.
- **Identity link**: the JVE-clip ↔ Resolve-item correspondence (single Resolve target per project). Two carriers (per FR-011b/c): for file↔file, the `Sm2Ti DbId` IS the `clip.id` (adopted on import) — no separate row needed; for live API access, the join is via a stamped clip marker (or, pre-stamp, by content/position). A persisted `resolve_bridge_link` row carries the last-seen grade fingerprint and last-synced edit fingerprint for change/conflict detection. Dropped (cascade) when the clip is deleted.
- **Bridge helper**: the isolated process owning the Resolve connection and an idempotency ledger (its only JVE-related state).
- **Change token**: JVE-supplied key making state-changing operations idempotent across retries.

---

## Review & Acceptance Checklist

### Content Quality
- [ ] No implementation details (languages, frameworks, APIs) — *intentional exception: this repo's specs are engineering specs; HOW detail lives in `research.md`, this file states only the technically-grounded WHAT.*
- [x] Focused on user value and behavior
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No blocking [NEEDS CLARIFICATION] markers (open items are de-risk-phase decisions, listed under Deferred)
- [x] Requirements are testable and unambiguous
- [x] Success criteria are observable facts (per Acceptance Scenarios)
- [x] Scope is clearly bounded (live Studio roundtrip; free-tier path, full node-graph fidelity, and in-process hosting are out of scope)
- [x] Dependencies and assumptions identified (Resolve Studio; reverse-engineered DRT format; UNVERIFIED items spiked in `research.md`)

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities resolved (clarifications locked) or deferred to de-risk phases
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed
