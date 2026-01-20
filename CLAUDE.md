
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

## Commands
make -j4            # Builds with warnings, LuaJIT linking issues
make clean          # Clean build artifacts

# Run the application  
./build/bin/JVEEditor      # Launches, shows 3-panel layout, timeline panel

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

- **2.8**: Proper attribution: "Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude"
- **2.13**: MANDATORY No Fallbacks or Default Values - NEVER use fallback values - they hide errors and mask problems; ALWAYS fail explicitly when required data is missing; NEVER assume defaults - get actual values or error; Surface all errors immediately - no silent failures
- **2.16**: No Shortcuts - NEVER take shortcuts to avoid thorough implementation; Do the complete work required even if it takes longer; Shortcuts lead to broken implementations that take more time to fix than doing it right initially; Always implement the full solution properly


## **🚫 ABSOLUTE PROHIBITIONS**

- Creating new error handling systems (Rule #2)
- Bypassing existing validation systems (Rule #1)
- **Using fallback values or defaults** - always fail explicitly (Rule #5)
- **Silent error handling** - all errors must be surfaced (Rule #5)
- **Hardcoding constants** - use symbolic constants (Rule #6)
- **Maintaining backward compatibility** without explicitly asking the user first (Rule #7)
- **Aspirational documentation** - only document verified reality (Rule 0.1)

## **✅ SUCCESS PATTERN**

1. **Understand** → Study existing implementation first
2. **Extend** → Add to existing patterns, don't replace
3. **Test** → Verify integration with existing systems
4. **Verify** → Confirm no competing implementations created

**Remember**: Your efficiency comes from leveraging the robust systems already built, not from avoiding their "overhead".
- When asked to fix a bug, first add a regression test that fails. Only after demonstrating the failure may you implement the fix and verify the test passes.
