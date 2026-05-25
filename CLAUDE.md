
This is a **Scriptable Video Editor Platform** modeled after Final Cut Pro 7, Resolve, and Premiere, written in Lua with C++ for speed where absolutely necessary.

## Active Technologies
- C++ (Qt6) + Lua (LuaJIT) hybrid architecture
- C++ for performance-critical: rendering, timeline manipulation, complex diffs
- Lua for UI logic, layout, interaction, extensibility
- SQLite for persistence
- Lua (LuaJIT) + C++ (Qt6) + Qt6 (dialogs), ffprobe (TC probing), dkjson (JSON) (002-relink-clips)
- SQLite (.jvp project files), `~/.jve/` for app prefs (002-relink-clips)
- C++ (Qt6) + Lua (LuaJIT) + Qt6 QShortcut, QKeySequence, QWidget::focusNextPrevChild (004-keyboard-architecture-refactor)
- TOML keybindings (`keymaps/default.jvekeys`) (004-keyboard-architecture-refactor)
- Lua (LuaJIT) + C++ (Qt6) + SQLite (persistence), command_manager (undo/redo), timeline_state (in-memory model) (005-gap-as-clip-refactor)
- SQLite for media clips (unchanged). Gaps are in-memory only — not persisted. (005-gap-as-clip-refactor)
- Lua (LuaJIT) + C++ (Qt6) + command_manager.lua, command_history.lua, SQLite (schema.sql) (006-per-sequence-undo)
- SQLite `.jvp` project files (006-per-sequence-undo)
- Lua (LuaJIT) + C++ (Qt6) + EMP (editor_media_platform), SQLite, ffprobe (TC probing), dkjson (JSON) (009-drp-importer-must)
- SQLite `.jvp` project files — new field in existing `metadata` JSON blob (no schema change) (009-drp-importer-must)
- Lua (LuaJIT) + C++ (Qt6) + Qt6 (via `qt_bindings.cpp` → `qt_constants.lua`), SQLite, `core/command_manager`, `core/signals`, `ui/selection_hub`, `ui/collapsible_section`, `inspectable/{clip,sequence}.lua` (012-rewrite-the-inspector)
- Project DB (SQLite `.jvp` files) for model state; new persistence file for collapse state (format resolved in Phase 0 — see research.md) (012-rewrite-the-inspector)
- Lua (LuaJIT) + C++ (Qt6). Lua is the dominant surface for this feature (data model, commands, resolver, overrides). C++ changes limited to the minimum needed for renderer/TMB recursion consumption. + Qt6 (UI + XML parsing), LuaJIT (scripting), SQLite3 (project storage), libzstd (DRP FieldsBlob decode — already landed earlier this session), nlohmann_json, FFmpeg (media decode), lsqlite3. (013-timeline-placements-as)
- SQLite `.jvp` project files. Schema change is substantial but unconstrained by back-compat requirements (FR-018). (013-timeline-placements-as)
- Lua (LuaJIT 2.1) + C++17 (Qt 6.x) + `core/signals.lua` (broadcast pub/sub), `core/database.lua` (SQLite connection + project-settings JSON I/O), Qt6 (single-shot timers via `qt_create_single_shot_timer`), background-worker thread for media probe (014-two-phase-project)
- SQLite `.jvp` project files; project settings live in `projects.settings` JSON column (014-two-phase-project)
- Lua (LuaJIT 2.1) for UI/command/data layers; C++17 (Qt 6.x) for performance-critical timeline/render layers (no C++ changes anticipated by this feature). + existing `core/command_manager`, `core/signals`, `core/ripple/batch/pipeline`, `core/clip_mutator`, `models/track`, `ui/timeline/timeline_panel`, `ui/source_viewer`, `ui/panel_manager`. SQLite (lsqlite3) for project persistence. JSON in `~/.jve/` for per-user app preferences. (015-source-in-timeline)
- SQLite `.jvp` project files. Forward-only migration: add `tracks.sync_mode` column; create `patches` table. Per-user preference `source_routing_view` persists as JSON in `~/.jve/` alongside existing prefs (`recent_projects.json`, `file_browser_paths.json`, etc.). (015-source-in-timeline)
- Lua (LuaJIT 2.1) for UI/commands/transport; C++17 (Qt 6.x) for `PlaybackController` (CVDisplayLink driven), TMB, audio device. + existing `core.playback.playback_engine`, `core.media.audio_playback`, `ui.panel_manager`, `ui.focus_manager`, `ui.timeline.timeline_state`, `models.sequence`, `core.signals`, `core.command_manager`. C++ side: `src/playback_controller.mm`, EMP (`TMB_*`, `MEDIA_*`), AOP/SSE. (017-refactor-playback-engine)
- SQLite `.jvp` project files. New per-project setting: `transport_target` in `projects.settings` JSON column. Sequence `playhead_frame` already persisted. (017-refactor-playback-engine)
- Lua (LuaJIT 2.1) for the model, command, importer, and edit-command layers; C++17 (Qt 6.x) for any binding-layer touches (none expected — this feature lives entirely above the C++/Qt boundary). (018-uniform-clip-source)
- SQLite `.jvp` project files. Schema bumps from V10 → V11 in this feature. (018-uniform-clip-source)
- LuaJIT 2.1 (UI, commands, source viewer state, edit_mode module) + C++17/Qt6 (one new mouse-event binding for timeline double-click only) + existing modules — `core/command_manager`, `core/signals`, `core/effective_source` (FR-016d amends contract), `core/commands/ripple_trim_edge` + `core/commands/batch_ripple_edit` (reused), `models/sequence`, `models/clip`, `ui/panel_manager`, `ui/focus_manager`, `ui/sequence_monitor`, `ui/source_viewer`, `ui/selection_hub`, `ui/project_browser`, `core/commands/match_frame` (binding unchanged), `keymaps/default.jvekeys` (keybinding additions), `view_bindings.cpp` (one new event binding) (019-source-viewer-clip-mode)
- SQLite `.jvp` project files — **NO schema change in 019**. Live-bound state is process-resident (`live_clip_id` on source_viewer module); no new entity. `clips.source_in_frame` / `source_out_frame` mutated by `RippleTrimEdge`/`OverwriteTrimEdge` are existing columns. Trim-mode toggle is process-state only, not persisted. (019-source-viewer-clip-mode)

READ ENGINEERING.md

## Project Structure
```
src/
  lua/
    core/           - Lua core including database and persistence
    commands/       - Command system backbone
    models/         - Data models
    timeline/       - Timeline management
    ui/             - UI components 
  main.cpp          - Application entry point
build/
    bin/
      JVEEditor         - Executable (builds, basic functionality)
tests/
```

## Project Database
- Location: `~/Documents/JVE Projects/Untitled Project.jvp` (SQLite)
- **Before any DB access**: check for running JVEEditor process. If none, `rm` the `-shm` file (stale shared memory). Leave the `-wal` file — it will be replayed on next launch.
```bash
pgrep -x JVEEditor || rm -f "$HOME/Documents/JVE Projects/Untitled Project.jvp-shm"
```

## Commands
make -j4            # Builds C++ AND runs luacheck on all Lua files AND all tests
make clean          # Clean build artifacts

**NOTE** don't run make|grep. instead send output to a /tmp file and grep that. running make takes real time!

**When iterating on UI changes**: use `cd build && make JVEEditor -j4` to build just the executable (skips tests). Run full `make -j4` (from repo root) only when ready to validate everything.

# Run the application
./build/bin/JVEEditor.app/Contents/MacOS/JVEEditor    # Launches, shows 3-panel layout, timeline panel
# or, for Finder/Dock launch with no args:
open build/bin/JVEEditor.app

## Dev Cycle — what to run after a change

Pick the single command that matches what you touched. The "final check" rows are mutually exclusive: running both in sequence is pure redundancy because `make -j4` already runs the full Lua suite.

| What you touched | Iteration loop                                              | Final check                |
|------------------|-------------------------------------------------------------|----------------------------|
| Lua only         | `cd tests && luajit test_harness.lua test_thing.lua`        | `./tests/run_lua_tests_all.sh` |
| C++ only         | `cd build && make JVEEditor -j4` (rebuilds binary, no tests) | `make -j4`                 |
| Lua + C++        | one of the above per iteration                              | `make -j4`                 |

`make -j4` runs everything (C++ compile, luacheck, full Lua suite, C++ tests, binding tests, integration tests). It is **never** correct to run `./tests/run_lua_tests_all.sh` *and* `make -j4` for the same change — `make -j4` already runs that script. Pick the one for your change class.

`make JVEEditor -j4` is the one exception that skips tests — use it during rapid UI iteration where you'll exercise the editor manually. Final validation still goes through the right row above.

Never run `make | grep` directly — `make` takes real wall time. Redirect to `/tmp` and grep the file:
```bash
make -j4 > /tmp/make.log 2>&1; grep -E "warning:|error:|FAILED" /tmp/make.log
```

## Running tests (mechanics)
```bash
# Run a single test (from tests/ directory)
cd tests && luajit test_harness.lua test_example.lua

# Run all Lua tests without stopping when one errors
./tests/run_lua_tests_all.sh
# Failures land in test-errors.txt
```

Tests are LuaJIT scripts in `tests/` with `test_*.lua` naming. Each test:
- Starts with `require('test_env')` to set up paths and utilities
- Creates its own test database in `/tmp/jve/`
- Uses `command_manager.execute()`, `command_manager.undo()`, `command_manager.redo()` directly
- Uses `print()` for test output (tests don't use logger module)
- Ends with `print("✅ test_name.lua passed")` on success

**IMPORTANT** Tests must be **black-box**: test outputs and side effects, not internals.
- **ZERO mocks** that encode assumptions about data or code paths. If a test builds data structures manually to simulate what code produces, it's testing assumptions, not code. Delete it.
- **Non-trivial values**: parameters that happen to be zero (source_in=0, offset=0) don't catch real bugs. Use values that exercise unit conversion, coordinate spaces, boundary conditions.
- **Interesting configurations**: muted clips, reversed clips, non-unity speed, BWF offsets, boundary-spanning segments. These are what break.
- A test that can't catch a real bug is **worse than no test** — it gives false confidence.
- **Test DOMAIN BEHAVIOR, not implementation.** Describe expected behavior without naming any function, variable, or module. If you can't, you're testing implementation. GOOD: "After relinking to a trimmed file, the clip plays the same content." BAD: "adjust_source_range returns source_in + offset." Derive expected values from domain requirements (timecode math, NLE conventions, what the user sees/hears), NEVER by tracing the code. If you computed the expected value by reading the implementation, the test just verifies the code does what the code does — worthless.
- **WARNING**: You WILL read code, form a model, and write tests that verify your model. You will believe you're testing behavior when you're testing implementation. The tell: if you derived the expected value by tracing the code, the test is worthless. Ask Joe "what should happen here?" rather than deciding yourself.

## Integration Testing with --test Mode
For features that need real C++ bindings (Qt widgets, XML parser, EMP/TMB, audio pipeline), use `--test` to run a Lua script inside the full JVEEditor process:

```bash
# Run a test script with full C++ bindings available
./build/bin/JVEEditor.app/Contents/MacOS/JVEEditor --test /tmp/my_test.lua

# With logging enabled
JVE_LOG=media:detail ./build/bin/JVEEditor.app/Contents/MacOS/JVEEditor --test /tmp/my_test.lua

# Save output for analysis (don't re-run the editor for each grep)
JVE_LOG=media:detail ./build/bin/JVEEditor.app/Contents/MacOS/JVEEditor --test /tmp/my_test.lua > /tmp/test_output.txt 2>&1
```

This is essential for:
- DRP import testing (needs `qt_xml_parse` C++ binding)
- Binding tests that exercise Qt widget creation
- Playback/audio pipeline tests that need TMB/SSE/AOP
- Any test that would otherwise require the user to manually operate the UI

**Always save output to a file** — don't pipe to grep directly, as re-running the editor for each query is wasteful. For Lua-only changes, `--test` doesn't require `make` (no C++ recompile needed).

## Logger Usage
Use the unified logger (never bare `print`). Each module binds to a functional area once:

```lua
local log = require("core.logger").for_area("ticks")  -- or: audio, video, timeline, commands, database, ui, media

log.detail("per-frame data: %d", frame)   -- high-frequency, off by default
log.event("state change: %s", state)      -- transitions, off by default
log.warn("suspicious: %s", msg)           -- survived but odd, ON by default
log.error("broken invariant: %s", msg)    -- broken, ON by default
```

C++ uses macros: `JVE_LOG_DETAIL(Ticks, ...)`, `JVE_LOG_EVENT(Ticks, ...)`, `JVE_LOG_WARN(Ticks, ...)`, `JVE_LOG_ERROR(Ticks, ...)`.

Control via env var: `JVE_LOG=play:detail,commands:event` (meta: `play`=ticks+audio+video, `all`=everything).

For short-term debug prints that will immediately be removed you may use print.

## Lua Error Handling in C++ Callbacks
When C++ code calls Lua callbacks (e.g., via `lua_pcall`), **NEVER silently log errors**. Instead:
- Use `JVE_ASSERT(false, err_msg)` to reset with a loud stack trace
- Lua's assert/error doesn't crash the app — it generates a stack trace and unwinds to the nearest pcall
- Stack traces are essential for debugging; silent logs hide bugs

## CRITICAL: Architecture — Model-View-Controller

This application is MVC. **Views pull from model state.** They NEVER depend on receiving an imperative push at the right moment.

- When a view is instantiated or becomes ready, it queries the model for what to display
- When the model changes (new data, state transition), it emits a signal; views listen and re-pull
- If a view can't answer "what should I be displaying right now?" by querying the model, the architecture is wrong
- Push-based delivery is acceptable ONLY on hot paths (60Hz playback); park mode (stopped/seeking) MUST be pull-based
- GPUVideoSurface is an implementation detail of the view — SequenceMonitor is the view

## CRITICAL: Main Engineering Principles to ALWAYS keep in mind:

### **1.14 FAIL-FAST ASSERT POLICY (Development Phase)**
- **Default posture**: This codebase is in active development. We prefer **immediate hard failure** over recovery. If a state *should never be possible*, it **must crash** loudly using an assert.
- **Use `assert()` aggressively** for invariant violations, including UI/editor invariants (e.g. missing `project_id`, `sequence_id`, `playhead`, “no tracks” when a timeline is active).
- **Don't use print** A “print and continue” is not acceptable for invariants.
- **Use logger module for info and debug prints**
- **No silent fallbacks**: Never invent `"default_project"`, `"default_sequence"`, default fps, etc. If required identifiers/metadata are missing, **assert with context**.
- **Renderer/UI paths may assert**: If invalid render inputs occur (bad colors, impossible geometry, etc.), crash immediately to force a fix. Prefer assert messages that identify the exact bad value and callsite.
- **Make crashes actionable**: Assert messages must include the function/module name and relevant IDs/parameters (sequence_id/track_id/clip_id/command name) so the root cause is obvious.
- **Do not add “graceful degradation”, retries, fallbacks, or compatibility shims** unless Joe explicitly asks for production-hardening behavior.

- **2.5**: Functions Read Like Algorithms - Functions should read like high-level algorithms that call subfunctions to do the dirty work; NEVER mix high-level logic with low-level implementation details in the same function; Break complex operations into well-named helper functions that handle specific concerns; Main functions should tell the story of WHAT happens, helper functions handle HOW it happens

- **2.8**: ALWAYS commit with proper attribution: "Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude"
- **2.13**: MANDATORY No Fallbacks or Default Values - NEVER use fallback values - they hide errors and mask problems; ALWAYS fail explicitly when required data is missing; NEVER assume defaults - get actual values or error; Surface all errors immediately - no silent failures
- **2.16**: No Shortcuts - NEVER take shortcuts to avoid thorough implementation; Do the complete work required even if it takes longer; Shortcuts lead to broken implementations that take more time to fix than doing it right initially; Always implement the full solution properly

## Compaction rules (JVE)
When compaction happens (manual or auto), preserve only:

- Current goal (1 line) + acceptance criteria
- Decisions made + brief rationale
- Next actions (3–10 bullets), in priority order
- Repo state: branch, key commits/hashes if mentioned, build config toggles, platform/tool versions if relevant
- Changes made: file paths + what changed (bullets per file)
- Repro + verification: exact commands run, failing tests/log snippets (only the essential lines), and what “green” looks like
- Invariants/constraints/preferences stated by the user

Drop:
- brainstorming, dead ends, long quotes, duplicate logs, verbose explanations, chit-chat

Format:
- bullets, no prose paragraphs
- end with a **NOW:** section listing the next 3 actions


## **⚠️ WARNINGS TO FUTURE CLAUDE — YOU WILL DO THESE THINGS. STOP.**

1. **"Pre-existing" label.** You will see test failures and call them pre-existing. You will use that word to skip investigation. Read every error message. Fix every failure. The word "pre-existing" is a stop sign in your head — override it.

2. **Tests that verify code, not behavior.** You will read the code, form a model, and write tests that confirm your model. The test will pass. The code will be wrong. Litmus: if you derived the expected value by tracing the code, the test is worthless. Expected values come from domain knowledge or from Joe.

3. **Proving innocence.** When a bug appears, you will try to prove your changes didn't cause it. Stop. Look at what's happening and fix it. Blame is irrelevant.

4. **"Fallback" values.** You will add `or 0`, `or default`, `or nil` to avoid a crash. Every one of those hides a real bug. Assert instead.

5. **Repo-wide destructive git commands that wipe state for other sessions.** You will reach for `git reset --hard`, `git stash -u`, `git clean -fd`, `git checkout .`, or history-rewriting rebases when you want to "clean up" before re-committing your work. **Joe runs multiple parallel Claude sessions on this repo.** Untracked files and uncommitted edits you don't recognize are almost certainly another Claude's in-progress work. If you reset-hard or stash-then-drop, you will destroy it silently — no assert, no warning, and by the time the other session notices, the reflog may already be pruned.

    **Rule: only touch the files you are working on.** If you need to rewrite history for YOUR commits, use file-scoped patch operations (`git diff -- path/to/your/file > /tmp/patch.diff`, `git reset --hard <base> -- path/to/your/file` is not a thing but `git restore --source=<base> -- path/to/your/file` is, and so is `git checkout <base> -- path/to/your/file`). Rebuild history with `git cherry-pick --no-commit` plus per-file `git add path/to/your/file`. NEVER `git reset --hard` the whole branch, NEVER `git stash -u`, NEVER `git clean`, NEVER `git checkout -- .`. If you believe you need to, STOP and ask Joe first.

    **What I did wrong (2026-04-10):** ran `git stash -u` to "save the working tree before rebuilding my 3 commits", which captured another Claude's in-progress `drp_importer.lua` edits and six untracked DRP files into the stash. Ran `git reset --hard b75755d`, cherry-picked + recommitted my work, then `git stash drop` because I thought the stash only contained changes I'd already re-applied. The drop orphaned the other Claude's work. Recovered it because Git's object store hadn't GC'd yet (`git show <dropped-stash-hash>:path/to/file`) — but that's a lucky recovery, not a safe workflow. The correct approach would have been to save ONLY my own files' diffs to patch files (`git diff -- src/mine.cpp`), leave everyone else's state in place, and rebuild by per-file checkout + patch apply.

## **🚫 ABSOLUTE PROHIBITIONS**

- **Patching over a broken model** — When a bug reveals a design gap, fix the model, don't add a special-case mechanism alongside it. If you're adding a heuristic, threshold, or flag to work around a failure in an existing system, STOP and ask: "Is the underlying abstraction wrong?" Special cases accrete into unmaintainable complexity. Priority flags, polling loops, and "near boundary" heuristics are symptoms of a missing abstraction, not solutions. If the fix doesn't make the system simpler, it's probably wrong.
- Creating new error handling systems (Rule #2)
- Bypassing existing validation systems (Rule #1)
- **Using fallback values or defaults** - always fail explicitly (Rule #5)
- **Silent error handling** - all errors must be surfaced (Rule #5)
- **Hardcoding constants** - use symbolic constants (Rule #6)
- **Maintaining backward compatibility** without explicitly asking the user first (Rule #7)
- **Aspirational documentation** - only document verified reality (Rule 0.1)
- **Command-specific logic in menu_system.lua** - menu dispatch must route through gather_context then command; no parameter resolution in menu handlers
- **The word "orchestration"** in code, comments, or commit messages — it substitutes for "algorithm" without claiming algorithmic rigor. Use precise terms: "tick loop", "audio-following", "change detection", etc.
- **fixing a failing test before being ABSOLUTELY SURE its failure is not surfacing a bug**
- **Choosing expedience over architectural correctness** — Before every decision, ask: "Is this the architecturally correct thing to do?" If the answer is no, don't do it. Don't add workarounds, caches that mask bugs, fallback values, or "temporary" hacks. Do the right thing the first time. If unsure, ask.
- **Lazy implementations that skip understanding** — Before modifying ANY subsystem, read 2+ working examples of the same pattern and trace the FULL execution path (execute → mutations → UI refresh → undo → mutations → UI refresh). Use the SAME mechanisms as existing code. Never write a no-op undoer or a `reload_timeline` fallback without understanding why the proper mutation path doesn't work. If you don't understand how something works, READ THE CODE — don't guess.
- **Blaming data instead of code** — When observed data doesn't match expectations (wrong IDs, missing records, unexpected values), the code that produced or consumed that data has a bug. NEVER theorize "stale data," "previous session," "test data issue," or "user error." Trace the code path that wrote the data. The unexpected data IS the bug symptom — investigate the implementation, not the data.
- **Trying to prove your changes didn't cause it** — When a bug appears after your changes, don't waste time proving innocence. Look at what's happening — that tells you both how to fix it AND whether your changes caused it. The fix is the main concern; blame is irrelevant.
- **Repo-wide destructive git commands** — `git reset --hard`, `git stash -u`, `git clean -fd`, `git checkout -- .`, `git restore .`, `git rm -rf`, force-push to main, and any history rewrite that touches files you didn't author. **Joe runs parallel Claude sessions.** Any uncommitted or untracked state you don't recognize belongs to a sibling session and is invisible to you until you destroy it. Scope every destructive operation to the specific files you authored: `git diff -- your/file`, `git checkout <commit> -- your/file`, `git restore --source=<commit> -- your/file`. If you can't accomplish your goal without touching state you didn't write, STOP and ask Joe first. See rule #5 under WARNINGS above for the specific incident and recovery procedure.

## **✅ SUCCESS PATTERN**

1. **Understand** → Study existing implementation first
2. **Research** → Don't reinvent the wheel. Look at the net for what other NLEs do - especially with performance-critical code.
3. **Extend** → Add to existing patterns, don't replace
4. **Test** → Verify integration with existing systems. You MUST write black-box as well as white-box tests. Black-box tests to make sure the standalone module and integrated modules do what they claim to do.
5. **Verify** → Confirm no competing implementations created

**Remember**: Your efficiency comes from leveraging the robust systems already built, not from avoiding their "overhead".

## **Key Patterns — 015-source-in-timeline**

- **Non-undoable commands**: set `SPEC.undoable = false` — track booleans (muted/soloed/locked/enabled via `ToggleTrackPreference`), patch routing (`SetPatch`), sync-mode (`SetSyncMode`) are NOT on the undo stack; `SetTrackMixValue` (volume/pan) IS undoable.
- **Dual timeline pointers**: `displayed_tab_id` (which tab is rendered) ≠ `active_sequence_id` (which sequence receives edits). Clicking Source tab changes only `displayed_tab_id`; edits always target `active_sequence_id`. Never conflate them.
- **Display-aware marks**: ruler and renderer must call `state.get_display_mark_in/out()` — returns source or record marks based on the visible tab. Never call `get_mark_in/out()` directly in rendering code.

**REMEMBER**: The planning module always writes plans in ~/.claude/plans. The names are meaningless so just sort by modification time to find the latest plans. DONT proceed from a handoff if you can't find the plan for it! Ask Joe if you need help.

## **🪶 CONTEXT DISCIPLINE**

Main session context grows fast and slows everything down. Two rules:

1. **Batch reads.** One `Read` of 200 lines beats six `Read offset=N limit=20`. One `rg` with a wide pattern beats five narrow ones. If you're about to do a third small read of the same file, read the whole region instead.
2. **Delegate multi-step investigation to subagents.** If a question needs >2 grep/Read calls to answer ("where is X used and which callsite needs the fix"), spawn an `Explore` subagent with `model: "haiku"`. The subagent burns its own context, you get back a summary. Spot-checks (one grep, one read) stay inline — subagent spawn overhead isn't worth it for those.

Cozempic guard auto-prunes at 200K/350K tokens, but don't rely on it — keep the context lean by default.

## **⚠️ REFACTOR SAFEGUARD**

**Before starting any refactor**: Run `git status`. If there are uncommitted or untracked files you don't recognize, **they belong to a parallel Claude session** — do not touch them, do not stash them, do not reset over them. Ask Joe before proceeding. Scope every subsequent git operation to the specific files you are refactoring. `git stash -u` and `git reset --hard` across the whole tree are forbidden because they silently destroy sibling-session work (see WARNING #5 and ABSOLUTE PROHIBITIONS above).

**Bug ownership**: Don't distinguish between "your" bugs and "pre-existing" bugs. If you find a bug, it becomes yours to fix. We care about fixing things, not about blame. "You" means Claude (any session), not just this specific context. Virtually all the code is written by you so you're the one who should fix it.

**When addressing a bug**: First write a regression test that fails. Verify the failure. Only then implement the fix and confirm the test passes.
