# Implementation Plan: User-Facing Bug Reporting Pipeline

**Branch**: `027-user-facing-bug` | **Date**: 2026-06-25 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/027-user-facing-bug/spec.md`

## Summary

JVE captures user activity into ring buffers; F12 packages a 5-minute slice (capture.json + slideshow.mp4) and the user reviews + submits via a dialog. Phase A makes the dialog produce a correct local zip (and opens it in Finder) — no network, no telemetry. Phase B replaces the Finder hand-off with a `POST /report` to a Cloudflare Worker, adds `/register` and `/heartbeat` for install-count telemetry, persists to R2 + D1, and gives Joe a Datasette triage view that can promote a cluster to a GitHub issue. Per FR-027 the Worker never auto-creates issues; promotion is Joe's explicit action.

The spec was revised through a skeptical-review pass on 2026-06-24 that resolved every prior open question (no `[NEEDS CLARIFICATION]` markers remain). This plan derives directly from the revised spec.

## Technical Context

**Language/Version**: LuaJIT 2.1 (UI/commands/transport policy), C++17 / Qt 6.x (FFI + hardware queries + HTTP), TypeScript (Cloudflare Worker only)
**Primary Dependencies**: Qt6 (Core, Widgets, Gui, Network — already linked), OpenSSL Crypto (already linked, for HMAC-SHA256 + SHA-256), dkjson (Lua JSON), lsqlite3 (Lua, existing), libzstd (existing, not needed here)
**Storage**: Cloudflare R2 (payload artifacts) + Cloudflare D1 (`installs`, `reports`, `clusters` tables) + local `~/.jve/install_id.json` (install_id + nonce) + local `~/.jve/pending-reports/` (offline retry queue) + local `tests/captures/<id>/` (in-memory then on-disk capture during Phase A)
**Testing**: `make -j4` (Lua via luacheck + targeted test_harness.lua; C++ via existing CTest; integration via `--test` mode). Phase A tests live in `tests/synthetic/lua/test_bug_reporter_*.lua`. Phase B contract tests for the Worker live alongside the Worker source (`bug-reporter-worker/test/*.test.ts`, run via `wrangler dev` + vitest).
**Target Platform**: macOS arm64 / x86_64 (primary); Linux/Windows return null for hardware fields (FR-016 + out-of-scope) without falling back silently.
**Project Type**: Single project — the JVE desktop app — plus a small separate Worker codebase at `bug-reporter-worker/` (deployed independently via `wrangler`).
**Performance Goals**: Submission round-trip ≤ 10 s for ≤ 5 MB payload on broadband (NFR-001); registration ≤ 2 s added to startup or async-deferred (NFR-002); heartbeat + submission never block UI thread (NFR-004); capture ring-buffer trim is O(1) amortized.
**Constraints**: Cloudflare free tier (10 GB R2 / 5 M D1 reads-day / 100k Worker req-day) MUST cover documented volume (500 lifetime reports / 100 installs) at $0 (NFR-003). 10 MB payload ceiling per FR-024a. Per-install daily cap of 20 reports per FR-023. Local pending queue cap of 50 reports per FR-024.
**Scale/Scope**: 100–500 installs over feature lifetime. 500 lifetime reports. Per-install daily volume bounded by FR-023.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Per `.specify/memory/constitution.md` v2.0.0:

- **I. Modular Architecture / MVC**: ✅ Submission dialog will be a view that pulls from a `bug_report_state` model (per ENGINEERING.md 3.0, called out as alignment note in spec). Capture, signature, transport, queue, and dialog are separate modules. Worker is its own codebase.
- **II. Command-Driven Interface**: ✅ `ReportBug` is already a registered command (`src/lua/core/commands/report_bug.lua:1`); F12 binding in `keymaps/default.jvekeys:32`. New commands (`OpenPreferencesPrivacy`?) — if added — will follow the existing command pattern. No menu-handler bypass.
- **III. Test-First Development**: ✅ TDD per FR alignment notes in spec. Each FR with observable behavior gets a failing test first. Black-box tests only — assertions describe user-visible outcome, never internal function names.
- **IV. Documentation-Driven Specifications**: ✅ Spec is the source of truth (36 FRs + 4 NFRs + 26 ASs). This plan derives from it.
- **V. Template-Based Consistency**: ✅ Plan/research/data-model/contracts/quickstart follow the templated structure.
- **VI. Fail-Fast Assert Policy**: ✅ FR-019a + FR-021a explicitly require asserts on malformed local state and malformed Worker responses. Spec forbids silent fallback.
- **VII. No Fallbacks or Default Values**: ✅ FR-024 splits rate-limit (discard with user-visible message) from transport failure (queue); neither is silent. FR-024 queue-overflow surfaces an unmissable warning. Linux/Windows null hardware fields are documented limitations (out-of-scope), not silent fallbacks.
- **VIII. No Backward Compatibility**: ✅ FR-036 deletes legacy YouTube/OAuth/old-submission modules. FR-030c rejects unknown schema versions explicitly. No migration shims for any old `capture.json` consumers — the new pipeline is the only consumer.

**Initial Constitution Check: PASS.**

## Project Structure

### Documentation (this feature)

```
specs/027-user-facing-bug/
├── plan.md              # This file
├── research.md          # Phase 0: brownfield code-grounding + decision log
├── data-model.md        # Phase 1: entities (matches spec D1 schema + local file shapes)
├── quickstart.md        # Phase 1: end-to-end smoke walkthrough for Phase A and Phase B
├── contracts/           # Phase 1: Worker endpoint contracts
│   ├── register.md
│   ├── heartbeat.md
│   ├── report.md
│   └── promote.md
└── tasks.md             # Phase 2 output (NOT created by /plan — /tasks does this)
```

### Source Code (repository root)

```
src/
├── lua/
│   ├── bug_reporter/
│   │   ├── init.lua                      # MODIFY: drop YouTube/OAuth init, add Phase A submit handler
│   │   ├── capture_manager.lua           # MODIFY: monotonic time, count caps per FR-010
│   │   ├── json_exporter.lua             # MODIFY: drop database_snapshots, inject schema_version + jve_sha
│   │   ├── utils.lua                     # KEEP
│   │   ├── qt_compat.lua                 # KEEP
│   │   ├── slideshow_generator.lua       # KEEP (called by exporter)
│   │   ├── signature.lua                 # NEW: normalize_error / normalize_title / sig (FR-012)
│   │   ├── transport.lua                 # NEW (Phase B): HMAC sign, POST, classify response (FR-021/021a/024)
│   │   ├── pending_queue.lua             # NEW (Phase B): ~/.jve/pending-reports/ enqueue/drain/cap (FR-024)
│   │   ├── install.lua                   # NEW (Phase B): install_id + nonce file mgmt + FR-019a assert
│   │   ├── hardware_snapshot.lua         # NEW (Phase B): CPU + GPU + memory via FFI (FR-016)
│   │   ├── telemetry.lua                 # NEW (Phase B): consent gate, register, heartbeat dispatch (FR-001/002/016/017/018)
│   │   └── ui/
│   │       ├── submission_dialog.lua     # REWRITE: thin view pulling from submission_state.lua
│   │       ├── submission_state.lua      # NEW: model (title, desc, text_only flag, telemetry-fields list)
│   │       ├── consent_dialog.lua        # NEW (Phase B): first-run consent (FR-001)
│   │       └── pref_privacy.lua          # NEW (Phase B): Preferences toggle (FR-002)
│   ├── core/
│   │   ├── build_info.lua                # NEW (Phase A): exposes git_sha generated from CMake
│   │   └── commands/
│   │       └── report_bug.lua            # MODIFY: call new submit pipeline; remove "test_path" naming
│   └── ...
├── bug_reporter/
│   ├── qt_bindings_bug_reporter.cpp      # MODIFY: target main window in grab; drop 1Hz log spam (FR-013)
│   ├── hardware_bindings.cpp             # NEW (Phase B): qt_get_cpu_info / qt_get_gpu_info_metal / qt_get_system_memory_mb
│   ├── http_bindings.cpp                 # NEW (Phase B): qt_http_post_multipart / qt_http_post_json (async via QNetworkAccessManager)
│   ├── crypto_bindings.cpp               # NEW (Phase B): qt_hmac_sha256 / qt_sha256 (OpenSSL)
│   └── gesture_logger.{h,cpp}            # KEEP
├── jve_build_info.h.in                   # NEW (Phase A): @JVE_GIT_SHA@ template
└── ...

bug-reporter-worker/                      # NEW (Phase B): separate Worker codebase
├── package.json
├── wrangler.toml
├── src/
│   ├── index.ts                          # Router: /register, /heartbeat, /report, /promote
│   ├── auth.ts                           # HMAC verify, install_id rate-limit check
│   ├── signature.ts                      # mirror of Lua signature.lua for verification
│   ├── d1.ts                             # typed wrappers around D1 statements
│   ├── r2.ts                             # zip storage + presigned-url helpers
│   ├── github.ts                         # promote-cluster → issue create (FR-029 idempotency)
│   └── migrations/
│       └── 0001_initial_schema.sql       # D1 schema per data-model.md
└── test/
    ├── register.test.ts
    ├── heartbeat.test.ts
    ├── report.test.ts
    └── promote.test.ts

tests/
├── synthetic/lua/
│   ├── test_bug_reporter_signature.lua            # NEW: FR-012 normalize_* + sig stability
│   ├── test_bug_reporter_capture_monotonic.lua    # NEW: FR-014 (AS #20)
│   ├── test_bug_reporter_capture_main_window.lua  # NEW: FR-013 (AS #19) — uses --test
│   ├── test_bug_reporter_artifact_shape.lua       # NEW: FR-011 + FR-011a + FR-015 (AS #21) — no .jvp, no raw PNGs
│   ├── test_bug_reporter_dialog_wiring.lua        # NEW: FR-009a (AS #22)
│   ├── test_bug_reporter_install_persist.lua      # NEW (Phase B): FR-019/019a (AS #23)
│   ├── test_bug_reporter_transport_classify.lua   # NEW (Phase B): FR-021a + AS #24 + AS #7 vs AS #6
│   ├── test_bug_reporter_queue_cap.lua            # NEW (Phase B): FR-024 cap + user-visible drop warning
│   ├── test_bug_reporter_payload_clamp.lua        # NEW (Phase B): FR-024a 10 MB ceiling
│   ├── test_bug_reporter_consent_gate.lua         # NEW (Phase B): FR-001 + FR-002 + AS #14 + AS #15
│   └── test_bug_reporter_telemetry_disabled.lua   # NEW (Phase B): zero traffic when disabled
└── (Worker tests live under bug-reporter-worker/test/)
```

**Structure Decision**: Single-project JVE Lua/C++ layout (matches existing `src/lua/bug_reporter/` + `src/bug_reporter/`) with a separate `bug-reporter-worker/` TypeScript subdirectory at repo root for Cloudflare Worker code. The Worker subdirectory is deployed independently via `wrangler` and tests are not part of `make -j4` (covered by `cd bug-reporter-worker && npm test`).

## Phase 0: Outline & Research

**Output: `research.md`**

Phase 0 does two things: (a) satisfies the BROWNFIELD CODE-GROUNDING GATE with a "Current State" subsection citing the modules this plan modifies, and (b) records every design decision in the spec with the rationale and rejected alternatives, so /tasks doesn't re-derive them.

Brownfield current-state coverage (full file reads cited in research.md):
- `src/lua/bug_reporter/init.lua` — lifecycle, gesture-logger install, screenshot timer, capture_screenshot wrapper
- `src/lua/bug_reporter/capture_manager.lua` — ring buffers, `os.clock()` bug, trim algorithm
- `src/lua/bug_reporter/json_exporter.lua` — `database_snapshots` leak, hardcoded `jve_version`, screenshot export
- `src/lua/bug_reporter/ui/submission_dialog.lua` — dialog construction, returns `widgets` table whose buttons are never wired (FR-009a target)
- `src/lua/core/commands/report_bug.lua` — register, dispatch, dialog open
- `src/bug_reporter/qt_bindings_bug_reporter.cpp` — `lua_grab_window` activeWindow bug (FR-013 target), per-call log spam
- `src/lua/qt_bindings/signal_bindings.cpp:601` — existing `qt_set_button_click_handler` we'll use for FR-009a
- `src/lua/qt_bindings/misc_bindings.cpp:63` — existing `qt_monotonic_s` we'll use for FR-014
- `src/lua/core/recent_projects.lua` — `~/.jve/<file>` access pattern we'll mirror for `install_id.json`
- `CMakeLists.txt` (line 36: OpenSSL Crypto linked; line 199: Qt6::Network linked) — confirms we have everything we need for HMAC and HTTP without adding dependencies

Decisions to record (with rationale + rejected alternatives):
1. **Per-install nonce in HMAC-SHA256 over body** vs. embedded global secret vs. mutual TLS — picked per-install for blast-radius reasons (spec FR-021/022).
2. **Cloudflare Worker + R2 + D1** vs. Postmark/SES + Gmail vs. self-hosted endpoint — picked CF for $0 cost ceiling and zero-ops profile.
3. **Manual promote-to-GH** vs. auto-create on first cluster — picked manual (FR-027) after review found user-story / FR-027 contradiction.
4. **Signature excludes jve_sha** vs. includes — picked exclude to avoid per-build cluster fragmentation.
5. **Strip trailing `ReportBug` from signature command tail** — F12 trigger MUST NOT dominate signature space.
6. **QNetworkAccessManager binding** vs. curl shell-out via QProcess vs. io.popen — picked QNetworkAccessManager binding (~150 lines C++) because async-native, Qt-event-loop-integrated, never blocks UI thread (NFR-004), and avoids `/usr/bin/curl` PATH dependency.
7. **OpenSSL HMAC-SHA256** (already linked) vs. Lua-only HMAC implementation — picked OpenSSL for correctness and speed; binding is ~20 lines.
8. **Metal device query for GPU** vs. `system_profiler` shell-out — picked Metal native (~15 lines `.mm`) per spec architecture; JVE already links Metal via GPUVideoSurface.
9. **`sysctlbyname` for CPU + memory** vs. shell-out to `sysctl` — picked native; ~30 lines, no fork cost.
10. **Schema version on every payload** (FR-030c) — picked to make breaking changes safe per protocol-versioning principle (Constitution III.1).
11. **Local pending-queue cap = 50 reports** (FR-024) — chosen to bound disk usage at ~250 MB worst case (50 × 5 MB) while giving comfortable retry headroom across multi-day outages.
12. **Payload ceiling = 10 MB** (FR-024a) — chosen to comfortably fit GitHub issue inline mp4 ceiling and stay well under R2 single-object cost band.
13. **Phase split (A then B)** — picked to bound risk; Phase A's capture-correctness fixes are independently shippable and improve `tests/captures/<id>/` artifacts even before backend exists.

**Verification**: All [NEEDS CLARIFICATION] markers absent from spec at time of plan. Phase 0 status: gated on writing the artifact (this section is the outline; the artifact is `research.md`).

## Phase 1: Design & Contracts

*Prerequisites: research.md complete*

**Outputs:**

1. **`data-model.md`** (Phase 1.1) — Mirrors the spec's D1 schema verbatim plus the local file shapes:
   - `installs`, `reports`, `clusters` tables (column types, indexes, constraints)
   - `~/.jve/install_id.json` shape: `{install_id, nonce, jve_sha, hardware_snapshot, consent_accepted_ts}`
   - `~/.jve/pending-reports/<uuid>.zip` (raw payload bytes) + `<uuid>.meta.json` (the multipart metadata that was supposed to ship)
   - In-memory ring-buffer shapes (matches existing capture_manager.lua entries)
   - State transitions: `installs.status` (`active` ↔ `suspended`), `clusters.gh_issue_url` (`null` → `https://...`)

2. **`contracts/register.md`** — `POST /register`:
   - Request: JSON body `{install_id, jve_sha, schema_version, platform, os_version, arch, cpu: {model, cores_physical, cores_logical, perf_cores?, eff_cores?}, system_memory_mb, gpu: {vendor, model, memory_mb, api, unified_memory}}`
   - Response: `{nonce: <64-hex>, server_ts: <unix>}` (200) or `{error: "install_id_exists" | "rate_limited" | "unknown_schema_version"}` (409/429/400)
   - Side effects per FR-016/025/030a/030b/030c
   - Idempotency: NOT idempotent — second call with same install_id returns 409 (FR-030a)

3. **`contracts/heartbeat.md`** — `POST /heartbeat`:
   - Headers: `X-Install-Id`, `X-HMAC` (HMAC-SHA256 hex of body), `X-Schema-Version`
   - Body: JSON `{ts: <unix>, hardware: <full snapshot — sent only when jve_sha changed since last heartbeat>}`
   - Response: `{server_ts: <unix>, status: "ok" | "suspended"}` (200/403)
   - Side effects: bump `installs.last_launched`; if hardware snapshot present, update hardware columns

4. **`contracts/report.md`** — `POST /report`:
   - Headers: `X-Install-Id`, `X-HMAC` over multipart raw bytes, `X-Schema-Version`
   - Body: `multipart/form-data` with two parts: `metadata` (JSON: `{signature, last_cmd, last_err, user_title, user_desc, capture_type, ts, text_only_flag}`) and `payload` (zip bytes)
   - Response: `{report_id, ref_short, cluster_id, cluster_count}` (200) or `{error: "rate_limited" | "payload_too_large" | "suspended" | "unknown_install" | "unknown_schema_version"}` (429/413/403/404/400)
   - Side effects per FR-023/024a/026/027/027a/028

5. **`contracts/promote.md`** — `POST /promote` (Joe-side only; uses a separate Joe-secret bearer auth, not the per-install nonce):
   - Headers: `Authorization: Bearer <joe-secret>`
   - Body: `{cluster_id, title_override?, body_override?}`
   - Response: `{gh_issue_url}` (200) or `{error: "already_promoted", gh_issue_url}` (200 — idempotent reconciliation per FR-029) or `{error: "cluster_not_found"}` (404)
   - Side effects: write `clusters.gh_issue_url`; comment on issue with backlinks to every member report

6. **Contract tests** — Generated alongside contracts, one file per endpoint, asserting request schema acceptance and response schema shape. Live in `bug-reporter-worker/test/*.test.ts` (vitest + Miniflare D1/R2 emulators). Must fail until the Worker is implemented.

7. **`quickstart.md`** — End-to-end walkthroughs:
   - **Phase A quickstart**: build → launch → F12 → fill dialog → Submit → Finder opens zip → verify zip contents (capture.json present, slideshow.mp4 present, no PNGs, no `.jvp`)
   - **Phase B quickstart**: `cd bug-reporter-worker && wrangler dev` (local) → launch JVE → first-run consent → /register fires → F12 → Submit → see report id → `wrangler d1 execute --local --command 'SELECT * FROM reports'` shows row → `datasette serve` shows clustered view → promote → issue appears in private repo

8. **Agent context update** — Run `.specify/scripts/bash/update-agent-context.sh claude` to add `(LuaJIT, Qt6, OpenSSL, dkjson)` + `(Cloudflare Worker / TypeScript / wrangler / D1 / R2)` to the active-technologies section of `CLAUDE.md`.

**Post-Design Constitution Check: PASS** (re-verified against Phase 1 outputs).
- I. MVC: `ui/submission_dialog.lua` rewrite explicitly creates `submission_state.lua` as a pulled-from view model — view never owns state.
- VI. Fail-fast: contract responses with `error` codes are surfaced by `transport.lua` as asserts only when the response is malformed (FR-021a). Known-error responses are surfaced as user-visible UI per FR-007.
- VII. No fallbacks: `install.lua` asserts on malformed `install_id.json` (FR-019a), never regenerates silently.

## Phase 2: Task Planning Approach

*Described here; NOT executed by /plan. `/tasks` consumes this section.*

**Task generation strategy** (per Constitution III. Test-First):

For each contract file:
1. Write the contract test (must fail — Worker route not implemented yet) — `[P]`
2. Implement the Worker route to make the test pass

For each entity in `data-model.md`:
1. Write the D1 migration SQL — `[P]` (if separate from prior migration)
2. Write a small fixture insert + select test against the migration

For each Phase A test in the test list above:
1. Write the failing test exercising the FR through observable behavior (no implementation function names in assertions per Constitution III black-box rule) — `[P]` across distinct files
2. Implement the smallest change that makes the test pass

For each Phase B test:
1. Same TDD order; Phase B tests `[P]` only across independent files (transport.lua, pending_queue.lua, install.lua are independent of each other)
2. Note: `signature.lua` test is shared between app side (Lua) and Worker side (TypeScript) since the Worker re-verifies signatures — write one canonical fixture file (`tests/fixtures/signature_vectors.json`) that both sides consume

**Ordering strategy**:
- Phase A first, end-to-end, including FR-035 (build-time SHA) since downstream tests need it.
- Phase B order: install.lua → hardware_snapshot.lua → telemetry.lua → http_bindings.cpp + crypto_bindings.cpp → transport.lua → pending_queue.lua → dialog wiring of submit handler → Worker `/register` → Worker `/heartbeat` → Worker `/report` → `/promote` last (depends on `clusters.gh_issue_url` write path).
- Legacy deletion (FR-036) lands after Phase A's new path is green so no legacy test is dropped while still passing.

**Parallelism markers**:
- `[P]` for files that touch no shared module (signature.lua test, capture_monotonic test, dialog_wiring test can all be written in parallel before any of them are implemented)
- NOT `[P]` for files that share a module under modification (capture_manager.lua tests must serialize against the capture_manager.lua impl)

**Estimated output**: 35–45 numbered tasks in tasks.md across Phase A (≈12 tasks) and Phase B (≈25–30 tasks) plus legacy-deletion (≈3 tasks) plus Joe-side ops (≈2 tasks: wrangler setup runbook, Datasette export script).

**IMPORTANT**: This phase is executed by `/tasks`, NOT by /plan.

## Phase 3+: Future Implementation

- **Phase 3**: `/tasks` creates `tasks.md`
- **Phase 4**: Implementation per Constitution III TDD discipline; targeted tests during iteration per CLAUDE.md, `make -j4` as the final gate
- **Phase 5**: Validation — run quickstart.md end-to-end on both Phase A (local zip) and Phase B (live `wrangler dev` + Datasette)

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Two delivery phases (A then B) rather than one big-bang | Phase A's capture-correctness fixes (FR-013/014/015) are independent of backend, and the in-tree `tests/captures/*` artifacts are unusable until landed. Shipping them behind a Phase-B-only release would delay improving Joe's local debugging artifacts for weeks. | One-shot release means all 36 FRs land together. Risk: Worker setup blocks for a week → no capture fixes for a week. Phasing decouples this without adding code complexity. |
| Separate TypeScript subdirectory (`bug-reporter-worker/`) at repo root | Cloudflare Workers require TypeScript/JS; no choice. | Run everything from Lua via curl shell-out: rejected for NFR-004 (UI thread blocking) and for losing CF's edge geolocation + native R2/D1 bindings. |
| New C++ bindings layer (http, crypto, hardware) instead of existing curl shell-out | Existing youtube_uploader.lua used `io.popen("curl ...")` — blocks Lua thread, susceptible to PATH issues per `feedback_finder_launched_app_path.md`. | curl shell-out: rejected for blocking + PATH issues. QProcess + /usr/bin/curl: acceptable fallback but no async response handling and slower per-call. Native QNetworkAccessManager binding: chosen — async, integrates with Qt event loop, ~150 lines. |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (`research.md` written by this plan run)
- [x] Phase 1: Design complete (`data-model.md`, `contracts/*`, `quickstart.md` written by this plan run, agent context updated)
- [x] Phase 2: Task planning complete (this section describes the approach; tasks.md NOT created here)
- [ ] Phase 3: Tasks generated (/tasks command — pending)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Brownfield Code-Grounding Gate: PASS (Current-State subsection present + cited in `research.md`)
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved (spec had none after revision)
- [x] Complexity deviations documented (3 entries above, all justified)

---
*Based on Constitution v2.0.0 - See `.specify/memory/constitution.md`*
