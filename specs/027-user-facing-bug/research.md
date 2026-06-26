# Phase 0 Research — User-Facing Bug Reporting Pipeline

**Spec**: [spec.md](./spec.md)
**Plan**: [plan.md](./plan.md)
**Date**: 2026-06-25

---

## Brownfield Code-Grounding Gate

Every architectural decision below derives from a full read of the modules this plan modifies. Citations are `file:line` of code read in this session (not subagent summaries).

### Current State — how the bug-reporter works today

#### `src/lua/bug_reporter/init.lua` (213 lines, read in full)

- `BugReporter.init()` (line 12) runs `capture_manager:init()`, installs the gesture logger, starts a 1 Hz QTimer that calls `BugReporter.capture_screenshot`.
- `BugReporter.capture_screenshot()` (line 79) calls `grab_window()` global (C++ binding). Working-tree edits (lines 86–102) added a `transport.record_engine:is_playing()` check that skips the grab during playback — workaround for main-thread stall during Metal surface readback.
- Per-tick log spam: `log.event("bug_reporter timer fired …")` + `log.event("bug_reporter grab_window: N ms …")` on every grab. Confirmed by TSO (line 7164+, this session): one line/sec forever.
- `capture_screenshot` is overridden onto the `capture_manager` table (line 113) — pixmap stored on each entry. This is the side door that puts a Qt userdata into the ring buffer.
- `set_enabled` (line 128) flips `capture_manager.capture_enabled` and starts/stops the timer.
- Module is `require`d and `init`ed from `src/lua/ui/layout.lua:142–145` once per project open (`do_open_project` → `bug_reporter.init()`). **Implication for FR-001**: the bug reporter currently activates on *project open*, not on app launch. Phase B's consent dialog must fire earlier in the launch sequence so `/register` precedes any opt-in-required path.

#### `src/lua/bug_reporter/capture_manager.lua` (329 lines, read in full)

- `MAX_GESTURES_IN_BUFFER = 200` (line 9). Commands, logs, screenshots **uncapped by count** — only by 5-minute time window. Spec FR-010 requires count caps on all four streams (gestures 200, commands 200, logs 1000, screenshots 300).
- `self.session_start_time = os.clock()` (line 37). `get_elapsed_ms()` uses `os.clock()` (line 53). **This is the FR-014 bug**: `os.clock()` is CPU time, not wall time. The 5-minute trim never fires when CPU time lags wall time. Explains the 2056-PNG capture artifact (78 MB) at `tests/captures/capture-2026-06-24_20-44-39-c3ef1e42/`.
- `trim_buffers()` (line 134) computes `cutoff_time` from `get_elapsed_ms()` — also CPU-time-based. Trim is O(n) per call (allocates new buffer, copies, replaces) but called only on insert, so O(1) amortized.
- `capture_screenshot()` (line 116) — base implementation stores a no-image entry. Real pixmap path is the override in `init.lua:113`. **Implication**: refactor to one canonical path; ring-buffer entry shape is `{timestamp_ms, image}` either way.
- `export_capture()` (line 277) sets `capture_enabled = false` during export ("freeze"), takes optional DB snapshot via `database.backup_to_file`. **FR-011a forbids this** — DB snapshot path is `tests/captures/<id>/bug-<datestamp>.db`, will leak project content. Must delete the DB snapshot branch entirely.

#### `src/lua/bug_reporter/json_exporter.lua` (253 lines, read in full)

- `json_data.capture_metadata.jve_version` hardcoded to `"0.1.0-dev"` (line 102). **FR-035 target**: replace with build-time-injected git SHA via `core.build_info.git_sha`.
- `json_data.database_snapshots = {before, after}` (line 116) — leaks .jvp paths into the metadata file. **FR-011a target**: remove entirely.
- `json_data.video_recording = {youtube_url, youtube_uploaded, ...}` (line 128) — vestigial YouTube fields. Remove for cleanliness.
- `export_screenshots()` (line 155) writes one PNG per buffer entry as `screenshot_NNN.png`. Slideshow generator (`bug_reporter.slideshow_generator`) consumes the directory; PNGs are not deleted afterwards. **FR-015 target**: cleanup step after slideshow.
- Schema version: the file uses `test_format_version = "1.0"` (line 93). This is the *capture format* version. Phase B's FR-030c requires a `schema_version` on the *payload envelope* — distinct field, will be set in the multipart metadata.

#### `src/lua/bug_reporter/ui/submission_dialog.lua` (358 lines, read in full)

- `SubmissionDialog.create(test_path)` (line 128) builds the dialog imperatively with `build_info_section` / `build_preview_section` / `build_options_section` / `build_button_row`, returns `{dialog, test_path, test, widgets={title_edit, body_text, upload_video, create_issue, privacy_combo, preview_video, submit, cancel}}`.
- **Critical**: the returned `widgets` table is **never read by anyone**. Confirmed via `rg -n "widgets\\.submit|widgets\\.cancel|widgets\\.preview_video"` (this session) — zero hits anywhere in `src/lua/`. The Submit button is a dead control. This is the user-reported "F12 didn't work" bug (the dialog opens, the button does nothing).
- The dialog still references `youtube_uploader`, `github_issue_creator`, "Upload slideshow video to YouTube" checkbox, "Create GitHub issue" checkbox, "Video privacy" combobox. All of those are FR-008 violations (user must never see GitHub/OAuth/YouTube) and must be removed.
- Constructed via `qt_compat.lua` (read in full) which proxies to `qt_constants` globals. No state model — pure imperative construction. **FR-009a + Constitution I (MVC) target**: rewrite as a view that pulls from `submission_state.lua`.

#### `src/lua/core/commands/report_bug.lua` (47 lines, read in full)

- Spec is single-registration shape with `executor = function(command)` (line 19) and `return {executor, spec}` (line 41). Registration plumbing is correct (matches `core/command_registry.lua:200+`).
- Body calls `bug_reporter.capture_manual(...)` then `qt_show_dialog(wrapper.dialog, false)` (line 32). Variable naming uses `test_path` — a holdover from the test-runner era; should be `capture_path`. Cosmetic.
- F12 binding confirmed at `keymaps/default.jvekeys:32`. End-to-end dispatch path verified in this session via TSO (line 534: dialog activated, became `qApp->activeWindow()`).

#### `src/bug_reporter/qt_bindings_bug_reporter.cpp` (502 lines, read in full)

- `lua_grab_window` (line 121) grabs `qApp->activeWindow()` with fallback to `qApp->topLevelWidgets().first()`. **FR-013 bug**: when any dialog (including the submission dialog itself) is the focused top-level, the grab captures that dialog instead of the JVE main window. Confirmed visually: capture directory contains 2055 PNGs at 376×396 (a panel that ate focus) after a single 3424×2070 main-window frame.
- Working-tree edits (lines 138–148) added `QElapsedTimer` instrumentation logging grab duration on every call. This was the diagnostic for the 1 Hz playback judder; the playback-skip in `init.lua` is the real fix. Per FR-010a-aligned plan: drop the instrumentation now that the skip is in place.
- `lua_create_timer` (line 192) creates a `QTimer` and registers a single-shot vs repeat-aware Lua callback. Reused as-is for the screenshot cadence in Phase A.
- The file also hosts mouse/key event posting (`lua_post_mouse_event`, `lua_post_key_event`, `lua_sleep_ms`, `lua_process_events`) for test replay. Out of scope for this feature; keep as-is.

#### `src/lua/qt_bindings/signal_bindings.cpp:601` (read in full around the function)

- `lua_set_button_click_handler` (line 601): takes a `QAbstractButton*` and a global Lua handler name; connects `clicked` signal to a `LuaHandlerCaller` invocation. **This is the FR-009a wiring primitive.** No new binding needed for button hookup; `submission_dialog` rewrite will set click handlers on `widgets.submit / .cancel / .text_only_checkbox` via this.

#### `src/lua/qt_bindings/misc_bindings.cpp:63` (read in full around the function)

- `lua_qt_monotonic_s` (line 63): `std::chrono::steady_clock::now()` cast to seconds. Documented at the function header as the correct alternative to `os.clock()` for cross-thread work. **This is the FR-014 fix primitive.** Replace `os.clock()` calls in `capture_manager.lua` with `qt_monotonic_s()` (Lua global). Convert to ms in `get_elapsed_ms()` by `* 1000`.

#### `src/lua/core/recent_projects.lua`

- Establishes the `~/.jve/<file>.json` access pattern (line 30: `home .. "/.jve/recent_projects.json"`). Used by `last_project_path` (`open_project.lua:453`), `file_browser_paths.json`, `find_dialog_settings.json`, etc.
- **Phase B install_id storage will mirror this pattern.** `~/.jve/install_id.json` with file perms 600 (via `utils.write_secure_file` which is already proven on the existing `~/.jve_youtube_token.json` and `~/.jve_github_token` paths in the to-be-deleted modules — same helper, new path).

#### `CMakeLists.txt`

- Line 24: `find_package(Qt6 REQUIRED COMPONENTS Core Widgets Sql Gui Multimedia Network)`. **Qt6::Network already linked** — no new dependency for `QNetworkAccessManager` HTTP binding.
- Line 36: `find_package(OpenSSL REQUIRED COMPONENTS Crypto)`. **OpenSSL libcrypto already linked** — no new dependency for HMAC-SHA256 and SHA-256 bindings.
- Lines 240–242: bundle identifier and version strings. The bundle short-version is the user-facing label; the build-time git SHA goes in a generated header (`jve_build_info.h`) consumed by both C++ and Lua (Lua via a binding that exposes the macro).

---

## Decision Log

Every decision is grounded in either the Current-State section above or in the locked spec. Items marked `[spec-locked]` were resolved during the spec's skeptical-review revision (2026-06-24) and are restated here only to make the rationale legible to /tasks.

### D-01: Per-install nonce HMAC (vs embedded global secret) `[spec-locked]`

- **Decision**: Each install gets a 32-byte random nonce at `/register`. Subsequent requests carry `X-HMAC = hex(HMAC-SHA256(nonce, body))`.
- **Rationale**: Blast radius. Compromise of one install's `install_id.json` lets the attacker submit on behalf of that install only. Backend revocation via `installs.status = 'suspended'` requires no rebuild (FR-022).
- **Rejected — Embedded global secret**: One leaked binary disk image compromises all installs; rotation requires shipping a new build to every user.
- **Rejected — mTLS**: Operational complexity (per-install certs) far beyond what this volume justifies.

### D-02: Cloudflare Worker + R2 + D1 (vs alternatives) `[spec-locked]`

- **Decision**: Worker on free `*.workers.dev`. R2 for zip artifacts. D1 for metadata.
- **Rationale**: $0 at documented volume (500 reports / 100 installs) with comfortable headroom. Zero-ops: no certs to rotate, no patches, no quota emails. `request.cf.{country,timezone}` resolves geo without storing IP.
- **Rejected — Postmark/SES + Gmail intake**: Adds a Joe-operated server (IMAP poller). Permanent ops tax.
- **Rejected — Self-hosted endpoint (Hetzner + Tailscale)**: Same ops tax, plus a box to keep up.
- **Rejected — Direct from app to GitHub API with bot token**: Token leaks on reverse-engineer; attacker can spam-create issues in Joe's repo bypassing all rate limits.

### D-03: Manual promote-to-GitHub (vs auto-create on first cluster) `[spec-locked]`

- **Decision**: Worker writes only to D1/R2 on `/report`. GitHub issue creation is triggered exclusively by Joe's `/promote` call from the triage UI.
- **Rationale**: Resolved the three-way contradiction between user story, original FR-027, and out-of-scope item ("Automatic promote-on-threshold deferred"). Joe is the triage gate; auto-create floods his inbox with raw-report duplicates of every transient bug.
- **Mitigation for stale GH issue counts after promotion** — FR-027a: Worker posts a comment on the GH issue every Nth new report bumping the cluster's count (default N=10).
- **Rejected — Auto-create on first occurrence**: Original FR-027. Contradicts user story.

### D-04: Signature excludes `jve_sha` (vs includes) `[spec-locked]`

- **Decision**: `sig = sha256(last_3_command_names_stripped.join(",") || normalize_error || normalize_title)`. Build identifier is preserved as a *column* on `reports`, NOT a signature input.
- **Rationale**: Including `jve_sha` fragments clusters per build. "RippleTrimEdge null deref" would reappear as a brand-new cluster on every version bump — defeats dedup exactly when it matters most.
- **Rejected — Include `jve_sha`**: Per above.
- **Rejected — Include `major.minor` of build**: Adds complexity; column-level filtering by Joe in Datasette achieves the same outcome.

### D-05: Strip trailing `ReportBug` from signature command tail `[spec-locked]`

- **Decision**: When computing signature, drop the trailing command if its name is `ReportBug`.
- **Rationale**: F12 itself dispatches the `ReportBug` command. Without this strip, every user-submitted capture has `ReportBug` as the last command, polluting the signature space and defeating dedup for user-submitted reports.

### D-06: QNetworkAccessManager binding (vs curl shell-out) `[plan-derived]`

- **Decision**: New C++ binding `qt_http_post_multipart` + `qt_http_post_json` wrapping `QNetworkAccessManager` async. Lua passes URL + headers + body + result-callback name. ~150 lines.
- **Rationale**: (a) NFR-004 requires non-blocking. `io.popen("curl ...")` blocks the calling thread. (b) `feedback_finder_launched_app_path.md` warns that Finder-launched `.app` has a stripped PATH — `curl` is at `/usr/bin/curl` but any future move to a non-system curl breaks. (c) QNetworkAccessManager integrates with Qt event loop, signals on completion, supports cancellation.
- **Rejected — `io.popen("/usr/bin/curl ...")`**: Blocks. PATH fragility on future portability moves.
- **Rejected — QProcess (already bound from spec 023) + `/usr/bin/curl`**: Async but no first-class header/body modeling, parsing curl output is fragile.

### D-07: OpenSSL HMAC + SHA-256 binding (vs pure-Lua) `[plan-derived]`

- **Decision**: New C++ binding `qt_hmac_sha256(key, message) -> hex` and `qt_sha256(message) -> hex` wrapping `EVP_MAC_CTX` and `EVP_Digest`. ~20 lines C++.
- **Rationale**: Already linked (`CMakeLists.txt:36`). Correctness + speed. Pure-Lua HMAC implementations exist but introduce a code-review burden for the project's security boundary that's hard to justify when libcrypto is already in the binary.
- **Rejected — Pure-Lua HMAC (e.g. `luaossl` or hand-rolled)**: Audit cost + extra dependency.

### D-08: Native Metal device query (vs `system_profiler` shell-out) `[plan-derived]`

- **Decision**: New `.mm` binding `qt_get_gpu_info_metal` that calls `MTLCreateSystemDefaultDevice()` and reads `.name`, `.recommendedMaxWorkingSetSize`, `.hasUnifiedMemory`. ~15 lines.
- **Rationale**: JVE already links Metal via GPUVideoSurface (`src/gpu_video_surface.h:149` cited in this session). No new dependency. `recommendedMaxWorkingSetSize` is the canonical Metal "GPU memory budget" — works for both unified-memory (AS) and discrete (Intel Mac w/ eGPU). Microseconds per call.
- **Rejected — `system_profiler SPDisplaysDataType -json` shell-out**: 200–500 ms per call, fork cost, JSON parsing.

### D-09: `sysctlbyname` for CPU + memory (vs shell-out) `[plan-derived]`

- **Decision**: New binding `qt_get_cpu_info` (returns `{model, cores_physical, cores_logical, perf_cores, eff_cores}`) and `qt_get_system_memory_mb` via `sysctlbyname("machdep.cpu.brand_string" | "hw.physicalcpu" | "hw.logicalcpu" | "hw.perflevel0.physicalcpu" | "hw.perflevel1.physicalcpu" | "hw.memsize")`. ~30 lines.
- **Rationale**: Microseconds, no fork. `perflevel{0,1}` fail silently on Intel — return nil, which the spec accepts (FR-016 marks them nullable).
- **Rejected — Shell `sysctl` invocations**: Fork cost.

### D-10: Schema version on every payload (FR-030c) `[spec-locked]`

- **Decision**: Every `/register`, `/heartbeat`, `/report` carries `X-Schema-Version: 1` (or a body field for `/register` which has no HMAC yet). Worker rejects unknown versions with 400.
- **Rationale**: Protocol versioning per Constitution III.1. When the payload envelope changes, the Worker side knows what to expect rather than silently coercing — same fail-loud principle as FR-021a/019a.

### D-11: Local pending-queue cap = 50 reports (FR-024) `[spec-locked]`

- **Decision**: `~/.jve/pending-reports/` capped at 50 entries; oldest dropped first; user warned via an unmissable UI surface (modal or banner) on each drop.
- **Rationale**: 50 × 5 MB = ~250 MB worst-case disk. Comfortable retry headroom across multi-day outages. Per-install daily cap of 20 (FR-023) means an offline week (~140 reports queued at worst) does exceed the cap — but that's the documented tradeoff; user is warned.

### D-12: Payload ceiling = 10 MB (FR-024a) `[spec-locked]`

- **Decision**: App clamps each outbound payload to 10 MB by (1) dropping oldest log entries, then (2) oldest commands, then (3) refusing to submit if still over after dropping everything but slideshow + most-recent commands + user description.
- **Rationale**: GitHub renders mp4 attachments inline up to ~10 MB. R2 single-object storage stays in the cheapest band. 5-minute slideshow at low bitrate is typically 2–3 MB; capture.json is tens of KB. Real-world payloads will rarely approach the ceiling.

### D-13: Phase A / Phase B split `[spec-locked]`

- **Decision**: Phase A ships capture correctness (FR-013/014/015), button wiring (FR-009a), build SHA (FR-035), partial legacy delete (FR-036 for YouTube/OAuth/old-submission), plus a "Reveal in Finder" Submit action standing in for the network path. Phase B replaces Finder hand-off with `/report` and adds telemetry, dedup, triage.
- **Rationale**: Phase A's capture-correctness fixes are independent of backend and improve `tests/captures/*` debug artifacts immediately. Phase B is risk-isolated: if `wrangler` setup blocks, Phase A is already merged.

### D-14: View pulls from a state model (Constitution I, MVC) `[constitution-derived]`

- **Decision**: `submission_dialog.lua` rewrite is a view that constructs widgets and binds them to read from + write to `submission_state.lua` (the model). State includes: `title`, `description`, `text_only_flag`, `telemetry_fields_about_to_ship` (resolved at dialog-open time), `captured_user_paths` (resolved at dialog-open time), `slideshow_preview_strip` (resolved from the on-disk slideshow).
- **Rationale**: The current dialog mixes layout, state, and missing button handlers in one imperative function. Constitution I requires views pull from model; "If a view can't answer 'what should I be displaying right now?' by querying the model, the architecture is wrong."

### D-15: Bug reporter init moves earlier in launch (Phase B implication of FR-001) `[plan-derived]`

- **Decision**: The `bug_reporter.init()` call in `src/lua/ui/layout.lua:142–145` (currently in `do_open_project`) becomes a two-phase init:
  - Phase A capture init still fires on project open (no behavior change).
  - Phase B `telemetry.lua` init fires at *app launch*, before any project is open. This is where the consent dialog (`consent_dialog.lua`) lives — FR-001 requires consent before any data leaves the machine, and the registration ping should happen on app startup not on project open.
- **Rationale**: Spec FR-016/017 measure "launches", not "project opens". Joe explicitly wants install-count and weekly-launch-count, not weekly-project-opens. Moving telemetry init earlier closes the gap.

---

## Open items deferred to /tasks (none requiring new clarification)

- Local pending-queue file naming convention (UUID vs. timestamp) — internal detail, will pick UUID for collision avoidance and write into `data-model.md`.
- Exact UI surface for "queue full, oldest dropped" warning (modal vs. persistent banner vs. notification toast) — FR-024 mandates "unmissable, not a log line"; modal is simplest. Pick during /tasks unless Joe weighs in.
- Worker bot account email + name. Joe creates `jve-bug-bot` account; ops detail; not gating /tasks.

No `[NEEDS CLARIFICATION]` markers remain. Spec + plan + research are internally consistent.
