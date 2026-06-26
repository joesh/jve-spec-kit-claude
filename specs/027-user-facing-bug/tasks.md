# Tasks: User-Facing Bug Reporting Pipeline

**Feature**: 027-user-facing-bug
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Research**: [research.md](./research.md) · **Data model**: [data-model.md](./data-model.md) · **Contracts**: [contracts/](./contracts/) · **Quickstart**: [quickstart.md](./quickstart.md)
**Date**: 2026-06-25 (revised after adversarial review same date)

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel — different files, no dependencies on other [P] tasks in the same row.
- Every task lists exact file paths.
- TDD ordering enforced: tests in each phase MUST be written and failing before implementation tasks in the same phase.

---

# Phase A — Capture trustworthiness + local submit loop (no backend)

**Exit criterion**: Joe presses F12, fills the dialog, clicks Submit, Finder opens with a clean zip containing capture.json + slideshow.mp4 and nothing else.

## Phase A · Setup

- [ ] **T001** Wire build-time git SHA injection (build-time, NOT configure-time).
  - Create `src/jve_build_info.h.in` with `#define JVE_GIT_SHA "@JVE_GIT_SHA@"`.
  - Edit `CMakeLists.txt`: add a custom target that runs on **every** build invocation (`add_custom_target(generate_build_info ALL ...)` with `BYPRODUCTS src/jve_build_info.h`). The command runs `git rev-parse --short=7 HEAD` and writes the header via `configure_file` only if the SHA changed (avoid touching the header when SHA is unchanged so `make` doesn't rebuild every TU each time). Reference impl pattern: <https://cmake.org/cmake/help/latest/command/add_custom_target.html#ALL>. `JVECore` `add_dependencies(JVECore generate_build_info)`.
  - Add Lua binding `qt_get_build_info()` returning `{git_sha=JVE_GIT_SHA}` in `src/lua/qt_bindings/misc_bindings.cpp`. Pattern: mirror `qt_get_pid` (line 75).
  - Create `src/lua/core/build_info.lua` exporting `{git_sha = qt_get_build_info().git_sha}`.
  - Acceptance: `make jve -j4` clean. `luajit -e 'print(require("core.build_info").git_sha)'` prints 7 hex chars. **Re-run check**: `git commit --allow-empty -m test && make jve -j4 && <relaunch JVE> && observe new SHA in capture_metadata.jve_version`.
  - **Drop the test commit** (`git reset --soft HEAD~1`) after verifying.

- [ ] **T001a** Create `tests/fixtures/signature_vectors.json` (shared by T002 Lua and T020 TS — was T019 in prior pass, moved here per ordering).
  - 6 input/expected-hash pairs covering: (a) user-submitted with normal title, (b) user-submitted with title containing punctuation/case-variation that should still cluster, (c) automatic with error containing absolute path that should normalize away, (d) automatic with error containing hex id, (e) capture whose last command is `ReportBug` (must be stripped), (f) capture with fewer than 3 prior commands.
  - Compute expected SHA-256 hashes by hand (or via `python3 -c 'import hashlib; print(hashlib.sha256(b"…").hexdigest())'`) using the canonical signature formula in data-model.md §Signature. Document the exact byte-string fed to SHA-256 alongside each vector.
  - Acceptance: file exists, valid JSON, 6 entries each with `{name, capture_type, last_commands, error_message, user_description, expected_sig}`.

## Phase A · Tests (TDD — MUST be written and FAILING before T007+)

- [ ] **T002 [P]** Write failing test `tests/synthetic/lua/test_bug_reporter_signature.lua`.
  - Black-box (Constitution III): test describes behavior, names neither functions nor modules in assertion messages.
  - Load `tests/fixtures/signature_vectors.json` (T001a). For each vector, invoke the signature module and assert output matches `expected_sig`.
  - Test loader guard: `local ok, sig = pcall(require, "bug_reporter.signature"); assert(ok or tostring(sig):match("not found"), "expected red until T008 lands")`. Without the guard, test failure looks like a missing-module crash; with it, the failure message says "T008 not done yet."
  - Covers FR-012.

- [ ] **T003 [P]** Write failing test `tests/synthetic/lua/test_bug_reporter_capture_monotonic.lua`.
  - Stub mechanism: monkey-patch `_G.qt_monotonic_s = function() return stub_value end` for the duration of the test (`teardown` restores the original). This is the dependency-injection point — capture_manager must call `qt_monotonic_s` as a global lookup at each use (not cache it at module-load), and T009 implementation MUST honor this so the stub takes effect.
  - Advance the stub to simulate "30 wall-minutes" of gestures appended. Assert ring buffer trims to entries whose simulated timestamp is within the last 5 minutes by wall age.
  - Also assert command and log buffers respect their per-stream count caps (200, 1000) by inserting >cap entries and verifying the cap holds.
  - Covers FR-010 + FR-014 + AS #20.

- [ ] **T004 [P]** Write failing test `tests/synthetic/lua/test_bug_reporter_capture_main_window.lua`.
  - Requires `--test` mode. Drive via `./build/bin/jve.app/Contents/MacOS/jve --test /absolute/path/to/test_bug_reporter_capture_main_window.lua` (CLAUDE.md memory: `--test` needs absolute path).
  - Open an auxiliary dialog (`qt_constants.DIALOG.CREATE(...)`) so it becomes the focused top-level. Wait one tick. Trigger capture by calling the screenshot timer's tick function directly.
  - Read back the most-recent screenshot's dimensions via `qpixmap_width(pixmap)` / `qpixmap_height(pixmap)` (NEW bindings — add as part of this test or as a sub-task of T010b; trivial wrappers around `QPixmap::width()/height()`).
  - Assert width ≥ 1000 (main window is large; any dialog is small). Covers FR-013 / AS #19.

- [ ] **T005 [P]** Write failing test `tests/synthetic/lua/test_bug_reporter_artifact_shape.lua`.
  - Requires `--test` mode (absolute path).
  - Stub user input: `qt_set_line_edit_text(dialog_title_widget, "test title")` for the title field. Programmatic click on Submit via `qt_set_button_click_handler` semantics — actually the test calls the Submit handler function directly (black-box: the handler is a public method on the dialog state model).
  - After export, assert exported directory contains exactly `capture.json` + `slideshow.mp4` + `<id>.zip` (NO `screenshots/` subdirectory remaining, NO `*.db`, NO `database_snapshots` key in `capture.json`).
  - Assert `capture.json.capture_metadata.jve_version` matches `^[0-9a-f]{7}$` (not `"0.1.0-dev"`).
  - Verify zip contents via `unzip -l` shell-out: exactly `capture.json` + `slideshow.mp4` listed, nothing else.
  - Covers FR-011 + FR-011a + FR-015 + FR-035 + AS #21.

- [ ] **T006 [P]** Write failing test `tests/synthetic/lua/test_bug_reporter_dialog_wiring.lua`.
  - Requires `--test` mode (absolute path).
  - Set env `JVE_BUG_REPORT_REVEAL_HOOK=/tmp/jve_test_reveal_<pid>.txt` IN THE PARENT SHELL before launching jve — Lua stdlib has no `setenv`, so the test invocation is `JVE_BUG_REPORT_REVEAL_HOOK=/tmp/... ./build/bin/jve.app/.../jve --test <abs-path>`. The reveal-in-finder binding (T014b) writes to this path instead of calling Finder when env var is set. **NO sentinel-in-production**: production code only consults the env var; if unset, calls Finder.
  - Open submission dialog. Read state model's `is_submittable` — assert false. Set title via state setter — assert `is_submittable` becomes true.
  - Invoke Cancel handler — assert dialog closes, env-var sentinel file NOT written.
  - Re-open, set title, invoke Submit handler — assert env-var sentinel file IS written and contains a zip path.
  - Toggle text-only flag, Submit again — `unzip -l <path-in-sentinel>` excludes `slideshow.mp4`.
  - Covers FR-009a + FR-006 + AS #22 + AS #8.

**Gate**: Run targeted Lua test for each of T002–T006 (`cd tests && luajit test_harness.lua synthetic/lua/test_bug_reporter_signature.lua` etc.) and confirm each FAILS with an actionable message (per T002 loader guard pattern). Do NOT proceed to T007 until each FAILS for the *right reason* (missing impl), not for harness reasons (missing fixture, missing binding).

## Phase A · Implementation

- [ ] **T007** Add SHA-256 binding in NEW file `src/bug_reporter/crypto_bindings.cpp`.
  - `qt_sha256(message: string) -> hex_string` via `EVP_Digest` with `EVP_sha256()`.
  - Add `src/bug_reporter/crypto_bindings.cpp` to `JVECore` CORE_SOURCES list in `CMakeLists.txt` (line ~152, immediately after `qt_bindings_bug_reporter.cpp`). `JVECore` already links `OpenSSL::Crypto` transitively via the find_package on line 36 — verified by recon.
  - Register via `lua_register(L, "qt_sha256", lua_qt_sha256)` in a `registerCryptoBindings(lua_State*)` function called from `qt_bindings.cpp`'s main registration.
  - Acceptance: `luajit -e 'print(qt_sha256("abc"))'` returns `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.

- [ ] **T008** Implement `src/lua/bug_reporter/signature.lua` (NEW file).
  - `M.compute(capture_type, last_3_commands, error_message, user_description) -> hex` per FR-012 + research D-04/D-05.
  - Strip trailing `ReportBug` entry from `last_3_commands` before joining.
  - `M.normalize_error(s)` and `M.normalize_title(s)` per data-model.md §Signature.
  - Calls `qt_sha256` (T007).
  - Acceptance: T002 passes against fixture vectors.

- [ ] **T009** Fix `src/lua/bug_reporter/capture_manager.lua`.
  - Replace every `os.clock()` with `qt_monotonic_s()` (existing binding at `src/lua/qt_bindings/misc_bindings.cpp:63`). Each call site looks up `qt_monotonic_s` as a global at use time (not cached at module-load) so T003's stub works.
  - Add count caps: gestures 200 (existing), commands 200 (NEW), logs 1000 (NEW), screenshots 300 (NEW). Pass to `count_removals` via each of the 4 call sites.
  - Remove the database-snapshot branch in `export_capture` (lines 286–295). `.jvp` content MUST NOT appear in any payload (FR-011a).
  - Acceptance: T003 passes; capture_manager file size doesn't grow significantly (this is correction + minor additions).

- [ ] **T010a** Set `objectName("JVEMainWindow")` on the JVE main window.
  - Per recon (R-02 + impl pass): main window is created in Lua at `src/lua/ui/layout.lua:350` via `qt_constants.WIDGET.CREATE_MAIN_WINDOW()`. `qt_set_object_name` binding already exists in `src/lua/qt_bindings/misc_bindings.cpp:854` (registered in `src/qt_bindings.cpp:396` as a global — implementation lives in misc_bindings rather than widget_bindings to avoid a forced QWidget cast). No new binding work; just the call site.
  - In `layout.lua`, immediately after `local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()` (line 350), add: `qt_set_object_name(main_window, "JVEMainWindow")`.
  - Acceptance: a small `--test` script that walks `qApp->topLevelWidgets()` finds a widget whose objectName is `"JVEMainWindow"`. Inline as a check in T004.

- [ ] **T010b** Fix `src/bug_reporter/qt_bindings_bug_reporter.cpp` `lua_grab_window` + remove log spam.
  - In `lua_grab_window` (line 121): iterate `qApp->topLevelWidgets()`, find the widget whose `objectName() == "JVEMainWindow"`. If not found (build before T010a landed, or test harness without the main window), assert via `JVE_ASSERT(false, "JVE main window not found — T010a not applied?")` (fail-fast per Constitution VI, NOT silent fallback to whatever happens to be focused).
  - Remove the `QElapsedTimer grab_timer` / `JVE_LOG_EVENT(Ui, "bug_reporter grab_window: …")` instrumentation block (lines 138–148).
  - In `src/lua/bug_reporter/init.lua`: remove the `log.event("bug_reporter timer fired …")` lines (around lines 100 and 104). Keep the playback-skip branch (lines 86–102).
  - Also add NEW bindings `qpixmap_width(pixmap)` / `qpixmap_height(pixmap)` to `src/bug_reporter/qt_bindings_bug_reporter.cpp` (wrappers around `(*userData)->width()/height()`), registered on the QPixmap metatable. Used by T004.
  - Acceptance: T004 passes; TSO is silent of per-second bug_reporter spam after a project is opened.

- [ ] **T011** Fix `src/lua/bug_reporter/json_exporter.lua` + add filesystem bindings.
  - Add NEW bindings to `src/lua/qt_bindings/misc_bindings.cpp` (recon R-03 confirms absent):
    - `qt_fs_listdir(path) -> array<string>` via `QDir::entryList(QDir::Files | QDir::NoDotAndDotDot)`.
    - `qt_fs_remove_dir_recursive(path) -> ok, errmsg` via `QDir(path).removeRecursively()`. Returns `(true, nil)` on success, `(false, "<reason>")` on failure.
  - In `json_exporter.lua`:
    - Remove `json_data.database_snapshots = ...` block (line 116).
    - Remove `json_data.video_recording = ...` block (line 128).
    - Replace hardcoded `"0.1.0-dev"` (line 102) with `require("core.build_info").git_sha`.
    - After `slideshow_generator.generate(...)` succeeds (line 80 area), call `qt_fs_remove_dir_recursive(screenshot_dir)`. Assert on failure with the returned errmsg + the directory path. FR-015.
  - Acceptance: T005 passes.

- [ ] **T012 [P]** Create `src/lua/bug_reporter/ui/submission_state.lua` (NEW file).
  - State table holds `{title, description, text_only, slideshow_thumbnails_path, captured_paths_list}` (telemetry fields land in Phase B).
  - `M.new()` returns a state instance. Pure-data setters (`set_title`, `set_description`, `toggle_text_only`).
  - `M:is_submittable()` returns true iff `self.title ~= "" and self.title ~= nil` (FR-004).
  - Emits `core.signals.emit("bug_report_state_changed")` on any setter (per recon R-04 pattern — established in sequence_monitor, source_viewer, etc.). View re-reads on signal.
  - Acceptance: covered by T006 as black-box consumer.

- [ ] **T013** Rewrite `src/lua/bug_reporter/ui/submission_dialog.lua` as a view.
  - View constructs widgets; binds them to `submission_state` per Constitution I MVC.
  - Wire Submit, Cancel, text-only checkbox via `qt_set_button_click_handler` (existing primitive at `src/lua/qt_bindings/signal_bindings.cpp:601`) and per-widget signal-binding patterns from existing dialogs (e.g. `find_dialog.lua`).
  - Submit handler: reads state, invokes `report_bug` command's submit entry point (added in T014c). Disables Submit when `!state:is_submittable()`.
  - Cancel handler: closes dialog without further action.
  - Text-only toggle handler: calls `state:toggle_text_only()`.
  - Phase A dialog content: title field + multiline description + slideshow thumbnail strip + text-only checkbox + Submit + Cancel. Drop every reference to YouTube/GitHub/OAuth/upload-video/create-issue/privacy-combobox.
  - Drop all `require` of soon-to-be-deleted modules (`youtube_uploader`, `github_issue_creator`, `bug_submission`, `oauth_dialogs`).
  - Acceptance: T006 passes.

- [ ] **T014a** Add a generic zip primitive — recon R confirms no general-purpose zip binding exists today (`qt_zstd_compress` is DRT-specific).
  - Implementation: `os.execute("/usr/bin/zip -j ...")` (revised from prior plan that called for `qt_process_start_sync` — `qt_process_*` are async + callback-driven, and adding a sync-wait binding just for this one caller would be scope creep). macOS ships `/usr/bin/zip` at a stable absolute path; using the absolute path inside the command line sidesteps the Finder-launched stripped-PATH trap (per CLAUDE.md memory `feedback_finder_launched_app_path.md`). %q-quote every argument so user paths can't escape into shell metacharacters.
  - Create helper module `src/lua/bug_reporter/zip_writer.lua` exporting `M.zip_files(output_path, file_paths) -> ok, errmsg`. The `-j` flag strips directory components so the zip contains just the basenames. Assert on non-zero exit.
  - Acceptance: a small Lua snippet zips two files; `unzip -l` shows them as flat entries.

- [ ] **T014b** Add reveal-in-Finder helper. **Spec sync (impl pass)**: implemented as the Lua module `src/lua/bug_reporter/reveal.lua` shelling `/usr/bin/open -R` rather than a `qt_reveal_in_finder` C++ binding. The C++ approach would have required AppKit framework linkage + objc_msgSend plumbing for a single one-shot user-visible action — disproportionate scope. The Lua module honors the same `JVE_BUG_REPORT_REVEAL_HOOK` test hook semantics.
  - On macOS: `/usr/bin/open -R <path>` via `os.execute` (absolute binary path defeats Finder-launched stripped-PATH trap).
  - On Linux/Windows: returns `false` immediately. Documented limitation per spec out-of-scope.
  - **Test hook**: if env var `JVE_BUG_REPORT_REVEAL_HOOK` is set to a file path, write the supplied path string to that file and return true. Production code branches on the env var (off by default in production launches), no sentinel-in-production pollution.
  - Acceptance: `require("bug_reporter.reveal").reveal("/tmp")` opens a Finder window (manual); with `JVE_BUG_REPORT_REVEAL_HOOK=/tmp/x` set, writes `/tmp` to `/tmp/x`.

- [ ] **T014c** Modify `src/lua/core/commands/report_bug.lua` for Phase A submit handler.
  - Rename internal `test_path` → `capture_path` (cosmetic, recon-confirmed in research D-02 note).
  - Add `M.submit(state)` exported function that the dialog's Submit handler invokes. Algorithm-style per ENGINEERING.md 2.5:
    1. `local capture_path = bug_reporter.capture_manual(state.title)`.
    2. `local files = {capture_path .. "/capture.json"}; if not state.text_only then table.insert(files, capture_path .. "/slideshow.mp4") end`.
    3. `local zip_path = capture_path .. "/" .. basename(capture_path) .. ".zip"`.
    4. `assert(zip_writer.zip_files(zip_path, files))`.
    5. `qt_reveal_in_finder(zip_path)`.
    6. Return `{ok=true, zip_path=zip_path}` for the dialog to display confirmation.
  - On preference toggle off (Phase B): show "Bug reporting is disabled" notice. **In Phase A, the preference toggle doesn't exist yet** — F12 always reaches submit. The disabled path is wired in T051.
  - Acceptance: T005 + T006 pass. Manual: F12 + title + Submit opens Finder showing the zip.

## Phase A · Legacy cleanup

- [ ] **T015** Delete Phase-A-safe legacy files (concrete list per recon R-08).
  - `rm` these source files:
    - `src/lua/bug_reporter/youtube_oauth.lua`
    - `src/lua/bug_reporter/youtube_uploader.lua`
    - `src/lua/bug_reporter/ui/oauth_dialogs.lua`
  - `rm` these test files (each requires only deleted modules — verified via recon):
    - `tests/synthetic/lua/test_upload_system.lua`
    - `tests/synthetic/lua/test_gui_runner.lua`
    - `tests/synthetic/lua/test_mocked_runner.lua` (requires `differential_validator`, `json_test_loader`, `test_runner_mocked` — all to be deleted; also deleting these source files in this task)
    - `tests/synthetic/lua/test_ui_components.lua` (requires `preferences_panel`, `oauth_dialogs`, `submission_dialog` — first two going, third is being rewritten; whole test is obsolete since T002–T006 cover the new shape)
  - `rm` these additional source files now (became orphans after deleting test_mocked_runner.lua above):
    - `src/lua/bug_reporter/differential_validator.lua`
    - `src/lua/bug_reporter/json_test_loader.lua`
    - `src/lua/bug_reporter/test_runner_mocked.lua`
    - `src/lua/bug_reporter/test_runner_gui.lua`
  - `rm` `src/bug_reporter/PHASE_1_COMPLETE.md` through `PHASE_8_COMPLETE.md`, `src/bug_reporter/PROJECT_COMPLETE.md`, `src/bug_reporter/INTEGRATION_GUIDE.md` (vintage Dec-2025 docs).
  - **Keep for Phase B**: `bug_submission.lua`, `github_issue_creator.lua`, `ui/preferences_panel.lua`. They will be deleted in T052 once Phase B replacements land.
  - `tests/synthetic/lua/test_bug_reporter_export.lua`, `test_capture_manager.lua`, `test_slideshow_generator.lua` SURVIVE (they exercise surviving modules).
  - `tests/synthetic/lua/test_bug_reporter_negative.lua`: requires `youtube_uploader` + `github_issue_creator`. youtube_uploader gone → file fails to load. Either rewrite to drop the youtube_uploader assertions (keep github coverage for Phase B), OR delete and rewrite from scratch in T052. **Decision**: delete now; T052 may add a fresh negative-test if needed once Phase B is wired.
  - Acceptance: `make -j4` passes with zero luacheck warnings about missing modules. No remaining `require` of deleted modules anywhere under `src/`.

## Phase A · Validation

- [ ] **T016** Walk Phase A quickstart end-to-end.
  - Execute every numbered step in [quickstart.md § Phase A](./quickstart.md) on the dev box.
  - Capture TSO. Verify all pass criteria.
  - Any deviation → fix-ticket against the failing T-NNN; do not mark T016 complete until all Phase A criteria hold.

---

# Phase B — Backend + telemetry + dedup + triage

**Exit criterion**: Joe sees a fresh report appear in Datasette within seconds of a user pressing F12, can sort by cluster count, and can promote a cluster to a real GitHub issue with one click.

## Phase B · Setup

- [ ] **T017** Scaffold `bug-reporter-worker/` TypeScript project.
  - From repo root: `npm create cloudflare@latest bug-reporter-worker -- --type=hello-world --ts --no-deploy --no-git` (cloudflare CLI flags as of 2026-06; if the flag set has churned, fall back to `npx create-cloudflare@latest bug-reporter-worker` and answer interactive prompts: TypeScript + Hello World + no deploy).
  - Add `vitest` + `@cloudflare/vitest-pool-workers` as devDependencies for Miniflare-backed contract tests.
  - Add `.gitignore` excluding `.wrangler/`, `node_modules/`, `dist/`.
  - Author `bug-reporter-worker/wrangler.toml` with placeholders: `r2_buckets`, `d1_databases`, `vars`, `triggers.crons = ["0 * * * *"]` (hourly — for the cleanup cron added in T-NEW-C).
  - Acceptance: `cd bug-reporter-worker && npm test` runs on the hello-world stub. `npx wrangler dev` boots.

- [ ] **T018** Author migration `bug-reporter-worker/migrations/0001_initial_schema.sql`.
  - Path: top-level `migrations/`, NOT `src/migrations/` (wrangler convention — corrected from prior pass).
  - All tables per [data-model.md §Tier 1](./data-model.md): `installs` (with `nonce TEXT NOT NULL`, NOT `nonce_hash`), `reports`, `clusters`, `report_idempotency`, `install_register_attempts`.
  - All indexes per data-model.
  - Acceptance: `wrangler d1 execute jve-bug-reports --local --file=migrations/0001_initial_schema.sql` succeeds; `--command=".schema"` lists all five tables.

## Phase B · Contract tests (TDD — MUST FAIL before T033+)

- [ ] **T020 [P]** Write failing `bug-reporter-worker/test/register.test.ts`.
  - Implements every bullet in [contracts/register.md § Contract test outline](./contracts/register.md).
  - Miniflare D1/R2 emulation. No real Cloudflare calls.
  - **Concurrency case** (added per adversarial review): two simultaneous `/register` calls from the same IP with different `install_id`s in the same hour window. Assert that the rate-limit counter reaches the correct final value regardless of interleaving (atomic upsert in T042 + T045 must guarantee no lost increments).

- [ ] **T021 [P]** Write failing `bug-reporter-worker/test/heartbeat.test.ts`.
  - Implements every bullet in [contracts/heartbeat.md § Contract test outline](./contracts/heartbeat.md).

- [ ] **T022 [P]** Write failing `bug-reporter-worker/test/report.test.ts`.
  - Implements every bullet in [contracts/report.md § Contract test outline](./contracts/report.md).
  - **FR-027 verification**: spy on `github.ts` module's `create_issue` export; assert it is NEVER called during any `/report` handling, only by `/promote`.
  - **FR-027a verification**: when `cluster.gh_issue_url` is set AND a `/report` bumps `count` past a multiple of N (default 10), assert `github.comment_on_issue` is invoked via `ctx.waitUntil` (verified by spy + flushing waitUntil queue in test).

- [ ] **T023 [P]** Write failing `bug-reporter-worker/test/promote.test.ts`.
  - Implements every bullet in [contracts/promote.md § Contract test outline](./contracts/promote.md).
  - Includes lost-response reconciliation (`gh_issue_url IS NULL` but label-search finds the existing issue).
  - All GitHub API calls mocked via vitest spies.

## Phase B · Lua-side tests (TDD — MUST FAIL before T030+)

- [ ] **T024 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_install_persist.lua`.
  - Valid `~/.jve/install_id.json` → loader returns the record.
  - Malformed JSON → loader asserts; `pcall` and verify error message contains the file path and `parse` (FR-019a / AS #23).
  - Missing `nonce` → loader asserts.
  - File permissions: after `write_secure_file`, `stat -f %A` returns `600`.

- [ ] **T025 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_transport_classify.lua`.
  - Monkey-patch `qt_http_post_json` / `qt_http_post_multipart` to return scripted responses.
  - 200 → app marks "delivered", returns `ref_short`. (AS #5)
  - 429 → app discards locally, surfaces "over today's cap" message. (FR-023 / AS #7)
  - 5xx → app enqueues to `~/.jve/pending-reports/`. (AS #6)
  - Network error (callback receives `error_message` non-nil) → app enqueues.
  - 200 status with non-JSON body (`"<html>..."`) → app asserts. Catch with `pcall`, verify message names the endpoint + the unparseable response. (FR-021a / AS #24)

- [ ] **T026 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_queue_cap_and_drain.lua` (renamed from prior `_queue_cap` — now covers both).
  - **Cap path**: insert 50 pending pairs; enqueue the 51st; assert oldest pair (by mtime) is deleted, new pair inserted, an unmissable-warning flag is set on a test-observable channel (e.g. a global counter or signal listener). (FR-024 cap)
  - **Drain success**: insert 3 pending pairs; mock transport to return 200 for all; run drain; assert all pairs deleted; assert no user-visible warning surfaced (drain success is silent per FR-024 drain semantics).
  - **Drain rate-limit**: insert 1 pending pair; mock transport to return 429; run drain; assert pair deleted; assert NO modal/banner surfaced (only a log line — drain-time 429 is log-only per amended FR-024).
  - **Drain transport error**: insert 1 pending pair; mock transport to return network error; run drain; assert pair STILL in place.
  - **Drain order**: insert 3 pairs with mtimes A < B < C; mock transport to record order of calls; run drain; assert call order is A, B, C.
  - Covers FR-024 fully.

- [ ] **T027 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_payload_clamp.lua`.
  - Construct synthetic capture with byte-size > 10 MB (e.g. 11 MB of synthetic log entries).
  - Assert clamp order: oldest log entries dropped first; commands dropped second; slideshow preserved; user description preserved.
  - Unclampable case: 11 MB slideshow alone → submission refused with user-visible error (FR-024a).

- [ ] **T028 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_consent_gate.lua`.
  - **Clarification on "spy"**: this test counts whether a function was called, not its return value. Per CLAUDE.md "no mocks that encode assumptions about data" — counting calls is verifying absence/presence of effect, not encoding data assumptions. Acceptable.
  - Wipe `~/.jve/install_id.json`. Boot test harness. Assert consent dialog state is shown.
  - Decline path: assert NO `qt_http_post_*` call observed. F12 → assert "Bug reporting is disabled" surfaced. (FR-009 / AS #14)
  - Accept path: assert `/register` POST observed; assert `install_id.json` exists.
  - Decline → flip preference toggle ON path: assert next backend interaction issues `/register` first (FR-002 / AS #15).

- [ ] **T029 [P]** Write failing `tests/synthetic/lua/test_bug_reporter_telemetry_disabled.lua`.
  - Preference toggle OFF; run a full session including F12 + Submit attempt. Assert zero `qt_http_post_*` calls of any kind (FR-020 / Success Criteria).

- [ ] **T029a [P]** Write failing `tests/synthetic/lua/test_bug_reporter_hardware_resnapshot.lua` (NEW per adversarial review).
  - Construct `~/.jve/install_id.json` whose `jve_sha_at_register` differs from `core.build_info.git_sha`. Trigger heartbeat.
  - Assert: the `qt_http_post_json` call's body contains a `hardware` field.
  - Trigger second heartbeat (still same sha mismatch since file not updated) → still includes hardware. Trigger a heartbeat after `install_id.json.jve_sha_at_register` is updated to match current sha → assert no `hardware` field. (FR-018)

**Gate**: Run `cd bug-reporter-worker && npm test` — T020–T023 MUST FAIL. Run targeted Lua tests for T024–T029a — each MUST FAIL with actionable assertion (per the loader-guard pattern from T002). Do NOT proceed to T030 until both gates show only the new tests as failing.

## Phase B · Native bindings (impl)

- [ ] **T030 [P]** Extend `src/bug_reporter/crypto_bindings.cpp` (created in T007).
  - Add `qt_hmac_sha256(key_hex: string, message: string) -> hex_string`. OpenSSL `HMAC` with `EVP_sha256()`. Key parsed as hex (stored nonce is hex).
  - Acceptance: `luajit -e 'print(qt_hmac_sha256("000102…3f", "test"))'` matches RFC 4231 vector.

- [ ] **T031 [P]** Create `src/bug_reporter/hardware_bindings.cpp` + `hardware_bindings.mm` (mac).
  - `qt_get_cpu_info()` (in `.cpp`) → `{model, cores_physical, cores_logical, perf_cores, eff_cores}` via `sysctlbyname` per research D-09. `perf_cores`/`eff_cores` are nil when `hw.perflevel*.physicalcpu` returns ENOENT.
  - `qt_get_system_memory_mb()` (in `.cpp`) → integer via `sysctlbyname("hw.memsize")`.
  - `qt_get_gpu_info_metal()` (in `.mm`) → `{vendor, model, memory_mb, api="Metal", unified_memory}` via `MTLCreateSystemDefaultDevice()` per research D-08. Set `gpu_vendor` based on `MTLDevice.name`: starts with "Apple" → "Apple"; "AMD" → "AMD"; "Intel" → "Intel"; "NVIDIA" → "NVIDIA"; else "Unknown".
  - `qt_get_uname()` (NEW, in `.cpp`, per recon R-05) → `{platform, os_version, arch}` via `<sys/utsname.h>` (`uname()` syscall). Platform: `utsname.sysname`. os_version: `utsname.release`. arch: `utsname.machine`.
  - Add `src/bug_reporter/hardware_bindings.cpp` and `hardware_bindings.mm` (conditionally on macOS) to `JVECore` CORE_SOURCES + UI_SOURCES. Link `Metal` framework (already linked via `gpu_video_surface.mm` per `CMakeLists.txt` mac-only block — verified).
  - Linux/Windows stubs return nil for `gpu_*` fields (documented limitation per spec out-of-scope, not silent fallback).
  - Acceptance: `luajit -e 'local x=qt_get_cpu_info(); print(x.model)'` prints `Apple M2 Pro` (or equivalent) on dev box. Same for GPU. `qt_get_uname().sysname` prints `Darwin`.

- [ ] **T032 [P]** Create `src/bug_reporter/http_bindings.cpp` (NEW file). **[P] — separate file, no shared-file conflict with T030/T031.**
  - `qt_http_post_json(url, headers_table, body_string, callback_name)` — async via `QNetworkAccessManager`. On reply: invoke Lua callback (looked up by name) with `(status_code: int, response_body: string|nil, error_message: string|nil)`.
  - `qt_http_post_multipart(url, headers_table, parts_table, callback_name)` — parts_table = `{[1]={name, content_type, body}, [2]={name, content_type, body}}`. Build `QHttpMultiPart` per `QNetworkAccessManager` docs.
  - QNetworkAccessManager instance owned by a long-lived QObject (singleton with `qApp` parent) so QNetworkReply objects survive across the binding call. Per research D-06: must NOT block UI thread.
  - Register in `JVECore` CORE_SOURCES + register globals in main qt_bindings init.
  - Acceptance: a manual smoke against a local Worker (or a one-off test echoing to httpbin.org) returns expected status; no blocking observed.

## Phase B · Lua modules (impl)

- [ ] **T033 [P]** Create `src/lua/bug_reporter/install.lua`.
  - `M.read()`: opens `~/.jve/install_id.json` (HOME via `os.getenv("HOME")`, mirroring `dialog_prefs.lua:18` pattern). Returns nil if file absent. Parses via `dkjson`. **Asserts on malformed JSON** with a message containing the file path and `parse` substring (FR-019a). Validates required fields (install_id UUID v4 regex match, nonce 64 hex regex match, consent_accepted_ts positive integer). Asserts on any missing/invalid.
  - `M.write(record)`: uses `utils.write_secure_file` (existing at `src/lua/bug_reporter/utils.lua:100`) for owner-only perms. Encodes via `dkjson.encode(record, {indent=true})`.
  - `M.generate_id()`: returns UUID v4 via `require("uuid").generate()` (existing module, used in `json_exporter.lua:54`).
  - Acceptance: T024 passes.

- [ ] **T034 [P]** Create `src/lua/bug_reporter/hardware_snapshot.lua`.
  - `M.snapshot()` returns the full hardware_snapshot table per data-model.md § Tier 2 (the `~/.jve/install_id.json.hardware_snapshot` shape).
  - Composes outputs of: `qt_get_uname()` (platform, os_version, arch), `qt_get_cpu_info()` (CPU), `qt_get_system_memory_mb()` (memory), `qt_get_gpu_info_metal()` (GPU).
  - Asserts that platform/arch are non-nil (these must succeed on every supported platform).
  - Acceptance: returned table validates against data-model shape; system_memory_mb > 0; cpu_cores_physical > 0.

- [ ] **T035 [P]** Create `src/lua/bug_reporter/transport.lua`.
  - Endpoint URL: `os.getenv("JVE_BUG_REPORT_ENDPOINT") or "https://jve-bug-relay.<workers-subdomain>.workers.dev"` (the prod URL is a module constant; env var override for dev/test).
  - **No fallback semantics — the constant IS the prod URL; absence of the env var means use prod.** Not a "default" hiding a missing config. Per ENGINEERING.md 2.13.
  - `M.post_register(body) -> response_or_error_table`: posts to `/register`, parses JSON response, returns `{ok=true, nonce, server_ts, country, timezone}` on 200, `{ok=false, code, retry_after?}` on known error codes, asserts on unparseable response per FR-021a.
  - `M.post_heartbeat(body, install_id, nonce) -> response_or_error_table`: HMAC body via `qt_hmac_sha256(nonce, body)`. Posts to `/heartbeat`. Same response shape as register.
  - `M.post_report(metadata_json, payload_zip_bytes, local_id, install_id, nonce) -> response_or_error_table`: compute signed payload per [contracts/report.md § Signed payload construction](./contracts/report.md): `metadata_json + "\n" + qt_sha256(zip_bytes)`. HMAC that. JSON serialization MUST use stable key ordering (sort keys alphabetically) so both sides reconstruct identical bytes.
  - Acceptance: T025 passes.

- [ ] **T036 [P]** Create `src/lua/bug_reporter/pending_queue.lua`. **[P] — separate file from T035; tests T026 mock transport directly so no inter-module dependency at file level.**
  - `M.enqueue(zip_bytes, metadata_json) -> local_id`: generate UUID, write `~/.jve/pending-reports/<uuid>.payload.zip` + `<uuid>.metadata.json`. If `count > 50`: delete oldest pair by mtime, call `signals.emit("bug_report_queue_cap_warning", {dropped_id})` so UI can surface a modal. Return the new local_id.
  - `M.drain(install_id, nonce)`: iterate oldest-first by mtime; for each pair call `transport.post_report(metadata, zip, local_id, install_id, nonce)`; classify response per amended FR-024 drain-time semantics:
    - 200 → delete pair (silent — log.event only).
    - 429 → delete pair (silent — log.event only; per FR-024 drain-time rule).
    - 5xx / network error → leave pair in place; STOP draining (don't hammer a sick server). Resume next launch.
    - Malformed response → assert per FR-021a.
  - Acceptance: T026 passes (all five sub-cases).

- [ ] **T037** Create `src/lua/bug_reporter/telemetry.lua` (depends on T033 + T034 + T035 + T036).
  - `M.init()` (called from app startup per T050; NOT project-open):
    - Read preference toggle via `dialog_prefs.load(dialog_prefs.path_for("bug_reporter_prefs.json"))` (per recon R-06).
    - If preference disabled → no-op (no register, no heartbeat).
    - If `install.read()` returns nil → show consent dialog (T038); register on accept.
    - If `install.read()` returns record → fire `transport.post_heartbeat` async; if `record.jve_sha_at_register ~= build_info.git_sha`, build heartbeat body with hardware snapshot and update `record.jve_sha_at_register` on response (FR-018).
    - After heartbeat (regardless of result), drain pending queue via `pending_queue.drain(install_id, nonce)`.
  - `M.register(consent_version)`: build body from `hardware_snapshot.snapshot()` + `install.generate_id()` + `build_info.git_sha` + `consent_version`. POST to `/register`. On success, write `install_id.json` via `install.write` with `{install_id, nonce, consent_accepted_ts=os.time(), consent_version, jve_sha_at_register, hardware_snapshot, country, timezone}`.
  - Acceptance: T028, T029, T029a pass.

- [ ] **T038 [P]** Create `src/lua/bug_reporter/ui/consent_dialog.lua`.
  - Modal dialog. Text loaded from `specs/027-user-facing-bug/consent-text-v1.md` (T-NEW-B) at module-load — read once, embed in dialog body widget. **Consent text is a versioned artifact, NOT a string literal in this file.** The integer `consent_version = 1` is bumped whenever the text materially changes; old consents are invalidated and the dialog re-shown.
  - Accept handler: call `telemetry.register(1)`.
  - Decline handler: set `dialog_prefs` `bug_reporter_enabled=false`; no register fired.
  - Wire via `qt_set_button_click_handler` per T013 pattern.
  - Acceptance: T028 covers the Accept/Decline paths.

- [ ] **T039 [P]** Create `src/lua/bug_reporter/ui/pref_privacy.lua` + integrate.
  - Per recon R-06: persistence path is `dialog_prefs.path_for("bug_reporter_prefs.json")`; key `bug_reporter_enabled` (boolean).
  - JVE has no consolidated Preferences UI shell today (recon: `src/lua/bug_reporter/ui/preferences_panel.lua` is the only file with "preferences" in the name, and it's being deleted in T052). For v1: expose a single command `TogglePreferenceBugReporting` (register in `src/lua/core/commands/toggle_preference_bug_reporting.lua` — new file) so the user can flip the toggle via command-palette / menu / shortcut. The full Preferences UI shell is a future feature.
  - Toggle ON: write `bug_reporter_enabled=true` via `dialog_prefs.save(...)`. If no `install_id.json` exists, fire `telemetry.register(1)`.
  - Toggle OFF: write `bug_reporter_enabled=false`.
  - Acceptance: T028 (FR-002 / AS #15) passes.

## Phase B · Worker modules (impl)

- [ ] **T040 [P]** Create `bug-reporter-worker/src/signature.ts`.
  - Mirror of `signature.lua` (T008). Same `normalize_error`, `normalize_title`, signature formula.
  - Read `tests/fixtures/signature_vectors.json` (T001a) in a startup-time assertion: every fixture's input must produce its expected hash. CI fails if Lua and TS diverge.

- [ ] **T041 [P]** Create `bug-reporter-worker/src/d1.ts`.
  - Typed helpers per data-model:
    - `installs.insert(record)` — uses `INSERT INTO installs (...) VALUES (...)`; column list matches schema.
    - `installs.update_last_launched(install_id, ts)` — `UPDATE installs SET last_launched = MAX(last_launched, ?) WHERE install_id = ?`.
    - `installs.update_hardware(install_id, fields)` — partial UPDATE only for non-nil fields in `fields`.
    - `installs.get(install_id)`, `installs.suspend(install_id)`.
    - `reports.insert(record)`, `reports.count_in_window(install_id, since_ts)`.
    - `clusters.upsert(signature) -> {id, count}` — atomic upsert returning post-update state.
    - `clusters.get(cluster_id)`, `clusters.set_gh_issue_url(cluster_id, url)`.
    - `report_idempotency.get(install_id, local_id)`, `report_idempotency.insert(install_id, local_id, report_id)`.
    - `install_register_attempts.atomic_increment_and_check(ip_hash, window_start, cap)` — atomic upsert + post-update read; returns `{count_after, exceeded}`.

- [ ] **T042 [P]** Create `bug-reporter-worker/src/auth.ts`. **[P] — separate file from T040/T041/T043/T044.**
  - `verify_hmac(install_id, signed_payload, x_hmac_header)`: look up `installs.nonce` (raw per data-model). Compute `HMAC-SHA256(nonce, signed_payload)`. Constant-time compare against `x_hmac_header`. Return `{ok:true}` or `{ok:false, code:"bad_hmac"|"unknown_install"|"suspended"}`.
  - `check_install_register_rate(ip_hash)`: call `d1.install_register_attempts.atomic_increment_and_check(ip_hash, current_hour, 5)`. Return `{ok:false, code:"rate_limited", retry_after_seconds}` if exceeded.

- [ ] **T043 [P]** Create `bug-reporter-worker/src/r2.ts`.
  - `put_report_zip(report_id, bytes)` → R2 PUT at `reports/<report_id>.zip`.
  - `get_report_signed_url(report_id, ttl_seconds)` → returns a presigned URL via R2's `createPresignedUrl` (Workers-API). **Choice (per adversarial review smaller-item): presigned URLs, NOT public-read bucket.** Triage UI requests a fresh URL per click; URLs expire after 1 hour. Reduces leak risk from URL sharing.

- [ ] **T044 [P]** Create `bug-reporter-worker/src/github.ts`.
  - `create_issue(cluster_id, title, body, labels)` → POSTs to GitHub API at `/repos/{owner}/{repo}/issues`. Uses `GITHUB_BOT_TOKEN` secret. Owner+repo from `wrangler.toml` env vars.
  - `find_issue_by_cluster_label(cluster_id)` → GETs `/repos/{owner}/{repo}/issues?labels=cluster:<id>&state=all`. For FR-029 reconciliation.
  - `comment_on_issue(issue_url, body)` → POSTs comment.
  - All calls instrumented so vitest spies in T022/T023 can verify call counts + args.

- [ ] **T045** Create `bug-reporter-worker/src/index.ts` with router skeleton + `/register` handler.
  - Match-on-path router; 405 for unsupported methods.
  - `/register` algorithm (per ENGINEERING.md 2.5):
    1. Parse and validate body (T020 enforces validation cases).
    2. `check_install_register_rate(sha256(request_ip))` → if rate-limited, 429.
    3. `installs.get(install_id)` → if exists, 409.
    4. Generate 32-byte nonce (`crypto.getRandomValues(new Uint8Array(32))` → hex).
    5. Resolve `request.cf.country / timezone`.
    6. `installs.insert({install_id, nonce, ...body, country, timezone, status:"active", first_seen:now, last_launched:now})`.
    7. Respond 200 with `{nonce, server_ts, country, timezone}`.
  - Acceptance: T020 passes.

- [ ] **T046** Add `/heartbeat` handler to `bug-reporter-worker/src/index.ts`.
  - Verify HMAC over body (T042). Update `installs.last_launched`. If body has `hardware`, update hardware columns via `installs.update_hardware`. Return `{server_ts, status}`.
  - Acceptance: T021 passes.

- [ ] **T047** Add `/report` handler to `bug-reporter-worker/src/index.ts`.
  - Algorithm:
    1. Parse multipart, separate metadata + payload.
    2. Reconstruct signed payload (`metadata_json + "\n" + sha256(zip_bytes)` per T035 spec-sync to contracts/report.md) and verify HMAC.
    3. Check `report_idempotency.get(install_id, local_id)` → if hit, return prior `{report_id, …}`.
    4. Check per-install daily rate (`reports.count_in_window(install_id, now-86400) < 20`).
    5. Validate zip contains `capture.json` entry (light check — parse zip directory, don't decompress).
    6. R2 PUT (`r2.put_report_zip`).
    7. D1 transaction: `clusters.upsert(signature)`, then `reports.insert(...)`, then `installs.update_*`, then `report_idempotency.insert`.
    8. If `cluster.gh_issue_url IS NOT NULL` AND `(cluster.count % N) == 0` (default N=10): `ctx.waitUntil(github.comment_on_issue(...))`. Response returns immediately; comment fires in background.
    9. Respond 200 with `{report_id, ref_short, cluster_id, cluster_count}`.
  - Worker MUST NOT call `github.create_issue` in this path — only `/promote` may (FR-027 verified by T022 spy).
  - Acceptance: T022 passes (including spy assertions).

- [ ] **T048** Add `/promote` handler to `bug-reporter-worker/src/index.ts`.
  - Bearer auth against `JOE_PROMOTE_SECRET`. Three-stage idempotency per [contracts/promote.md § Idempotency](./contracts/promote.md):
    1. Fast path: `clusters.gh_issue_url` set → return 200 `created:false`.
    2. Reconcile: `github.find_issue_by_cluster_label(cluster_id)` → if found, update D1 + return 200 `created:false`.
    3. Create: `github.create_issue(...)`, update `clusters.gh_issue_url`, `github.comment_on_issue(...)` with member listing → 201 `created:true`.
  - Acceptance: T023 passes.

## Phase B · Wire-up

- [ ] **T049 [P]** Extend `src/lua/bug_reporter/ui/submission_dialog.lua` + `submission_state.lua` for Phase B.
  - State adds:
    - `telemetry_fields_about_to_ship` (resolved at dialog-open by querying `install.read().hardware_snapshot` + `country` + `timezone` + `build_info.git_sha`).
    - `captured_user_paths` (resolved at dialog-open by scanning the in-memory log buffer for strings matching the regex `[/~][A-Za-z0-9_./%-]*`, deduplicated). **Concrete regex** addresses adversarial-review smaller-item: matches absolute Unix paths and tilde-expanded paths; false-positive risk on URLs and arbitrary strings starting with `/` is accepted for v1.
  - Dialog adds two read-only widgets in the privacy preview section: (a) telemetry fields table, (b) captured user paths list.
  - Submit handler changed: instead of zip+reveal-in-Finder, call `transport.post_report(...)`. On success show "Report sent — reference #<ref_short>"; on rate-limit show "Over today's submission cap — try again tomorrow"; on transport error call `pending_queue.enqueue(...)` and show "Queued for retry on next launch".
  - **[P] with T050**: separate files.

- [ ] **T050 [P]** Add `telemetry.init()` to app startup. **[P] with T049: separate files.**
  - Per recon R-07: Lua handles startup via `src/lua/ui/layout.lua` (top-level execution). The main window is created at line 350; `SHOW` is called at line 739.
  - Insert `require("bug_reporter.telemetry").init()` in `layout.lua` between window-create and SHOW (after T010a's `qt_set_object_name` call so the consent dialog can attach to the parented main window). Wrap in `pcall` so consent-dialog failure doesn't break app startup; assert on the result and log warn — fail-loud per Constitution VI but app survives so the user can disable bug reporting.
  - Existing `bug_reporter.init()` inside `do_open_project` (`layout.lua:142–145`) STAYS — that's the capture init; telemetry init is separate.
  - Acceptance: T028 + T029 + T029a pass; manual: relaunch JVE without opening a project, observe `/heartbeat` in `wrangler dev` log.

- [ ] **T051** Update `src/lua/core/commands/report_bug.lua` for Phase B.
  - Remove the T014c reveal-in-Finder path. Submit handler now delegates entirely to `submission_dialog`'s submit which calls transport (T049).
  - On preference toggle off: show "Bug reporting is disabled; enable in Preferences → Privacy" notice via `qt_constants.DIALOG.CREATE` modal and dismiss (FR-009 / AS #14).
  - Depends on T049 (uses its submit handler).

## Phase B · Legacy cleanup

- [ ] **T052** Delete remaining legacy files.
  - `rm src/lua/bug_reporter/bug_submission.lua`
  - `rm src/lua/bug_reporter/github_issue_creator.lua`
  - `rm src/lua/bug_reporter/ui/preferences_panel.lua`
  - Verify no `require` of these modules anywhere via `rg "bug_submission|github_issue_creator|preferences_panel" src/lua/`.
  - Acceptance: `make -j4` zero warnings.

## Phase B · Joe-side operations

- [ ] **T053 [P]** Create `bug-reporter-worker/triage-promote.html`.
  - Single static file served by a Worker route (`/triage-promote.html`).
  - JS reads `cluster_id` from URL query string, reads `JOE_PROMOTE_SECRET` from `localStorage`, POSTs to `/promote`, displays returned `gh_issue_url`.

- [ ] **T054 [P]** Create `docs/bug-reporter-ops.md`.
  - Contents per [quickstart.md § Joe-side operational notes](./quickstart.md): one-time setup, weekly triage, secret rotation, "disabling Worker analytics IP capture".

## Phase B · NEW tasks (per adversarial review)

- [ ] **T-NEW-A** Polish: run `make scan` (clang static analyzer) on the new C++ files.
  - New C++ files this feature adds: `crypto_bindings.cpp`, `http_bindings.cpp`, `hardware_bindings.cpp`, `hardware_bindings.mm`, plus modifications to `qt_bindings_bug_reporter.cpp` and `widget_bindings.cpp` and `misc_bindings.cpp`.
  - Per CLAUDE.md: `make scan` runs scan-build into `build-scan/`. Run before merging Phase B.
  - Acceptance: any findings either fixed or explicitly documented as accepted false positives in a tracked-bug note. Zero severity-high findings.

- [ ] **T-NEW-B** Author `specs/027-user-facing-bug/consent-text-v1.md`.
  - Final wording the consent dialog shows (FR-001). Lists every data category collected: install id, JVE version, OS + version, architecture, CPU model + cores, system memory, GPU vendor + model + memory + API, country (resolved server-side from IP), timezone (resolved server-side). States explicitly: no usernames, no hostnames, no IP addresses persisted, no project content, no file system contents outside the capture artifact.
  - Versioned: this file is v1. Changes that materially alter what's collected bump version → invalidate old consents → re-show dialog.
  - Acceptance: T038 reads this file at module-load and embeds in dialog body.

- [ ] **T-NEW-C** Implement Cloudflare Workers Cron Trigger for cleanup.
  - In `bug-reporter-worker/src/index.ts`: export a `scheduled(event, env, ctx)` handler.
  - Hourly cron (configured in `wrangler.toml:triggers.crons = ["0 * * * *"]` per T017) executes:
    - `DELETE FROM install_register_attempts WHERE window_start < (current_hour - 24)`.
    - `DELETE FROM report_idempotency WHERE created_at < (now - 604800)` (7-day TTL).
  - Acceptance: Miniflare scheduled-handler test asserts both DELETEs run; verifies rows older than TTL are removed.

- [ ] **T-NEW-D** R2 access pattern lock — already documented (spec-sync applied during /tasks pass): see [contracts/promote.md] derived-body paragraph and [data-model.md § reports.r2_key] comment. This task remains as an implementation gate: verify T043's `get_report_signed_url` uses 1-hour TTL and that promote.ts (T048) inlines fresh presigned URLs into the GitHub issue body, NOT a stable public URL. No further documentation work needed in this task.

- [ ] **T-NEW-E** Wire `JVE_BUG_REPORT_ENDPOINT` env var override end-to-end.
  - `transport.lua` (T035) already consults `os.getenv`. Add a build-time check at module-load: if neither env var nor the constant URL is set to a `https://` value, assert.
  - Document in `docs/bug-reporter-ops.md` (T054): override only for local dev / contract tests.

## Phase B · Validation

- [ ] **T055** Walk Phase B quickstart end-to-end per [quickstart.md § Phase B](./quickstart.md). Capture TSO; verify pass criteria.

- [ ] **T056** Re-run Phase A quickstart for regression.
  - Phase B touched `submission_dialog.lua`, `report_bug.lua`, `layout.lua`. Re-execute Phase A quickstart in full — the local-zip path no longer exists, but the capture-correctness pieces (FR-013/014/015) must still hold.
  - If any Phase A pass criterion now fails, fix and re-run T055 + T056.

---

# Dependencies

```
T001 (CMake SHA, build-time) → T001a (signature fixtures)
                            │
                            ▼
T002 [P]  T003 [P]  T004 [P]  T005 [P]  T006 [P]   ← Phase A TDD gate before T007+
   │       │        │         │         │
   │       │        │         │         └─► T012 → T013 → T014a → T014b → T014c
   │       │        │         │             └─► T015 (after T013 drops dead requires)
   │       │        │         │
   │       │        │         └─► T011 (also: needs new qt_fs_* bindings)
   │       │        │
   │       │        └─► T010a → T010b
   │       │
   │       └─► T009
   │
   └─► T007 → T008

T016 (Phase A validation)  — after T015 (everything Phase A landed)

──── Phase A complete ────────────────────────────────────────────────

T017 (Worker scaffold) → T018 (D1 migration top-level migrations/)

T020 [P]  T021 [P]  T022 [P]  T023 [P]   ← Worker contract tests failing
T024 [P]  T025 [P]  T026 [P]  T027 [P]  T028 [P]  T029 [P]  T029a [P]   ← Lua tests failing

──── Phase B TDD gate before T030+ ────

T030 [P]  T031 [P]  T032 [P]   ← bindings
   │       │        │
   ▼       ▼        ▼
T033 [P]  T034 [P]  T035 [P]   ← Lua wrappers
   │       │        │
   └───────┴────────┴───────► T036 [P] (parallel — uses transport.lua but file-disjoint)

T036 + T033 + T034 + T035 ───► T037 (telemetry — composes all)
                                │
                                ├─► T038 [P]
                                └─► T039 [P]

T040 [P]  T041 [P]  T042 [P]  T043 [P]  T044 [P]   ← Worker source modules (all file-disjoint)
   │       │        │         │         │
   └───────┴────────┴─────────┴─────────┴─► T045 → T046 → T047 → T048   ← all touch index.ts; sequential

T049 [P] + T050 [P]  — (after T037–T039); different files
T049 → T051

T052 (final legacy delete)  — after T049 (drops remaining stale requires)

T053 [P]  T054 [P]   ← ops docs

T-NEW-A   T-NEW-B   T-NEW-C   T-NEW-D   T-NEW-E   ← polish
  │         │         │         │         │
  │         └─► T038 reads this artifact
  │
  └─► run before Phase B merge

T055 (Phase B quickstart) → T056 (Phase A regression check)
```

# Parallel execution examples

**Phase A tests in parallel** (after T001a):
```
Task: "Write failing test per T002"
Task: "Write failing test per T003"
Task: "Write failing test per T004"
Task: "Write failing test per T005"
Task: "Write failing test per T006"
```

**Phase A independent impl in parallel** (after gate):
```
Task: "T009 capture_manager monotonic + count caps"
Task: "T010a + T010b main-window targeting + log spam removal"
Task: "T011 exporter fixes + qt_fs_* bindings"
Task: "T012 submission_state model"
```

**Phase B contract + Lua tests in parallel**:
```
Task: "T020 register contract test"
Task: "T021 heartbeat contract test"
Task: "T022 report contract test"
Task: "T023 promote contract test"
Task: "T024 install_persist test"
Task: "T025 transport_classify test"
Task: "T026 queue cap+drain test"
Task: "T027 payload_clamp test"
Task: "T028 consent_gate test"
Task: "T029 telemetry_disabled test"
Task: "T029a hardware_resnapshot test"
```

**Phase B Lua modules in parallel** (after bindings + tests fail):
```
Task: "T033 install.lua"
Task: "T034 hardware_snapshot.lua"
Task: "T035 transport.lua"
Task: "T036 pending_queue.lua"
```

**Phase B Worker modules in parallel** (after bindings + tests fail):
```
Task: "T040 Worker signature.ts"
Task: "T041 Worker d1.ts"
Task: "T042 Worker auth.ts"
Task: "T043 Worker r2.ts"
Task: "T044 Worker github.ts"
```

# Validation Checklist

- [x] All 4 contracts have contract tests (T020–T023).
- [x] All 5 D1 entities covered by T018 migration + T041 d1.ts wrappers.
- [x] Every endpoint has an implementation task (T045/46/47/48).
- [x] Every Lua module in plan §Project Structure has a task.
- [x] Every native binding has a task (T007/30/31/32 + qt_set_object_name in T010a + qt_fs_* in T011 + qt_reveal_in_finder in T014b + qpixmap_width/height in T010b + qt_get_uname in T031).
- [x] Every acceptance scenario in spec.md maps to at least one test:
  - AS #1, #14, #15 → T028
  - AS #2 → T020 + T028
  - AS #3 → T021 + quickstart step 7
  - AS #4 → T006 (Phase A) + T049 (Phase B fields)
  - AS #5 → T025 + T049
  - AS #6 → T025 + T026
  - AS #7 → T025
  - AS #8 → T006 + T027
  - AS #9, #10 → T022
  - AS #11 → quickstart step 11 (T055)
  - AS #12 → T023 + quickstart step 12
  - AS #13 → T022 (FR-027a verified)
  - AS #16 → T021 + T025
  - AS #17 → T025
  - AS #18 → T029a (NEW) + T021 (hardware update column)
  - AS #19 → T004
  - AS #20 → T003
  - AS #21 → T005
  - AS #22 → T006
  - AS #23 → T024
  - AS #24 → T025
  - AS #25, #26 → T020
- [x] TDD ordering enforced via explicit gates and dependency graph.
- [x] All verify-or-do antipatterns removed (recon completed in /tasks; concrete instructions in each task).
- [x] All [P] markers correct (T032, T036, T042, T049, T050 fixed per adversarial review).

---

# Notes

- **Spec-sync done in this pass**:
  - **spec.md FR-024**: amended with drain-time semantics (silent on success and 429; in-place on transport error; cap warning is the only user-visible drain surface).
  - **contracts/report.md** (during T035 implementation, called out in T035 body): HMAC over `metadata_json + "\n" + sha256(zip_bytes)`, not "raw multipart bytes". Implementation must apply this spec-sync.
  - **data-model.md / contracts/promote.md** (T-NEW-D): R2 access via presigned URLs, not public-read.
- **Open implementation choices decided in this pass**:
  - Pending-queue file naming: `<uuid>.payload.zip` + `<uuid>.metadata.json` (data-model § Tier 2).
  - Queue-full warning UI: modal dialog via `qt_constants.DIALOG.CREATE`.
  - Preferences storage: `dialog_prefs.path_for("bug_reporter_prefs.json")`, key `bug_reporter_enabled`.
  - No consolidated Preferences UI shell in v1; the toggle is a registered command (`TogglePreferenceBugReporting`).
  - R2 access: presigned URLs (not public-read).
  - Worker scheduled-task: Cloudflare Cron Triggers; `comment_on_issue` runs via `ctx.waitUntil` (non-scheduled, fires async during `/report`).
- **Constitution III spy clarification**: tests counting whether a function was called (T022/T023 GitHub spy; T028 transport spy) are verifying absence-of-effect, not encoding data assumptions. Acceptable. Tests that mock RETURN VALUES are not introduced anywhere; transport tests use monkey-patched stubs to script SCENARIOS (200/429/5xx/network/malformed), which is sequence injection, not value invention.
- **Commit cadence**: per task. Per Constitution III, failing test first → commit, then impl → commit. Attribution per ENGINEERING.md 2.8.
- **`make -j4` is the final gate** per CLAUDE.md authority. Targeted tests during iteration; full make at end of each task.
