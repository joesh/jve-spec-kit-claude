
This is a **Scriptable Video Editor Platform** modeled after Final Cut Pro 7, Resolve, and Premiere, written in Lua with C++ for speed where absolutely necessary.

## Active Technologies
- C++ (Qt6) + Lua (LuaJIT) hybrid architecture
- C++ for performance-critical: rendering, timeline manipulation, complex diffs
- Lua for UI logic, layout, interaction, extensibility
- SQLite for persistence

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
make -j4            # Builds C++ AND runs luacheck on all Lua files
make clean          # Clean build artifacts

# Run the application
./build/bin/JVEEditor      # Launches, shows 3-panel layout, timeline panel

## Dev Cycle
After any Lua change: `make -j4` which will run luacheck (0 warnings required) and all the Lua tests

## Running Tests
```bash
# Run all Lua tests without stopping when one errors
./tests/run_lua_tests_all.sh

# Run a single test (from tests/ directory)
cd tests && luajit test_harness.lua test_example.lua

# Test output goes to test-errors.txt for failures
```

Tests are LuaJIT scripts in `tests/` with `test_*.lua` naming. Each test:
- Starts with `require('test_env')` to set up paths and utilities
- Creates its own test database in `/tmp/jve/`
- Uses `command_manager.execute()`, `command_manager.undo()`, `command_manager.redo()` directly
- Uses `print()` for test output (tests don't use logger module)
- Ends with `print("✅ test_name.lua passed")` on success

**IMPORTANT** When writing tests use the ABSOLUTE MINIMUM set of mocks. Mocks are bad. They encode incorrect assumptions about how the real code works. Avoid them if at all possible.

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

## **✅ SUCCESS PATTERN**

1. **Understand** → Study existing implementation first
2. **Research** → Don't reinvent the wheel. Look at the net for what other NLEs do - especially with performance-critical code.
3. **Extend** → Add to existing patterns, don't replace
4. **Test** → Verify integration with existing systems. You MUST write black-box as well as white-box tests. Black-box tests to make sure the standalone module and integrated modules do what they claim to do.
5. **Verify** → Confirm no competing implementations created

**Remember**: Your efficiency comes from leveraging the robust systems already built, not from avoiding their "overhead".

**REMEMBER**: The planning module always writes plans in ~/.claude/plans. The names are meaningless so just sort by modification time to find the latest plans. DONT proceed from a handoff if you can't find the plan for it! Ask Joe if you need help.

## **⚠️ REFACTOR SAFEGUARD**

**Before starting any refactor**: Run `git status` and warn the user if there are uncommitted changes. Refactors should start from a clean working tree so changes can be tracked, reviewed, and reverted if needed. Commit or stash existing work first.

**Bug ownership**: Don't distinguish between "your" bugs and "pre-existing" bugs. If you find a bug, it becomes yours to fix. We care about fixing things, not about blame. "You" means Claude (any session), not just this specific context. Virtually all the code is written by you so you're the one who should fix it.

**When addressing a bug**: First write a regression test that fails. Verify the failure. Only then implement the fix and confirm the test passes.
