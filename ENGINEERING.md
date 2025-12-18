# Codex Instructions - JVE (Joe's Video Editor)

- Be collaborative, thoughtful, creative, warm and friendly, act like a peer

- When presenting feedback such as plans and code reviews: consider readability, such as larger fonts for section headings, leading emojis, bold text, using bullet points, numbered lists, code blocks, whitespace. Use the fidelity of markdown formatting. Have a sense of style and presentation

## **🔧 USEFUL DEBUGGING TIPS**
We've got lots of context available when anything goes wrong:
	The persistent database is at ~/Documents/JVE\ Projects/Untitled\ Project.jvp
	A full log of what's happened is in ./tests/captures


## **🔧 DEVELOPMENT RULES**

### Process (Mandatory)
- See `DEVELOPMENT-PROCESS.md` for the required workflow used for all future changes (scope/contracts, invariants, and test-gated verification).

### **0. Todo Management & Session Continuity**
- **ALWAYS write to TODO.md** for real-time task tracking
- **UPDATE immediately** when starting/completing/discovering tasks
- **CHECK todo list FIRST** before asking what's next
- **Mark in_progress BEFORE starting, completed IMMEDIATELY after finishing**

### **0.1 MANDATORY Documentation Honesty**
- **NEVER write "complete/ready/working" without personal verification**
- **NO aspirational language** - describe what IS, not what should be
- **LIST broken/incomplete items explicitly**
- **BEFORE updating status docs**: Run tests AND verify functionality
- **ACCOUNTABILITY**: Every claim must be verifiable

### **0.2 Context Preservation for Auto-Compact**
- **ALWAYS update SESSION-STATE.md** as you learn critical architectural details
- **DOCUMENT decisions and discoveries** immediately - don't rely on chat memory
- **INCLUDE current bug status** and fix progress in context file
- **ADD breakthrough insights** about codebase design and user preferences
- **PRESERVE context continuity** - assume future Claude has no memory of this session

### **1.x Core Development Standards**
- **1.1**: Comprehensive error handling upfront (not iterative debugging). While in development mode asserts are fine. Later we'll want full cascading error handling. Key is to fail fast with a stack trace as soon as an issue is found.
- **1.2**: Test before assuming - validate everything incrementally
- **1.3**: Don't change what's working without proven need
- **1.4**: Modular architecture - single responsibility, clean separation
- **1.5**: MANDATORY data-driven config - NO hardcoded UI styles/schemas/lists
- **1.6**: MANDATORY universal state persistence - all widgets inherit PersistentWidget
- **1.8**: Always analyze existing patterns before implementing - Study existing code patterns before writing any new code; find similar implementations; use established conventions; document pattern decisions
- **1.9**: Respect the Architecture - NEVER bypass existing abstractions (error system, widget registry, Lua API); ALWAYS use existing patterns - don't invent new approaches; If unsure, ask - don't guess and implement
- **1.10**: Stay in Your Layer - Lua scripts call Qt bindings - never direct Qt; Use widget registry RAII handles - never manual memory management; Go through command dispatcher - never direct function calls
- **1.12**: External inputs must NEVER crash the system - all imported data (XML, DB, files) must be validated; degrade gracefully when metadata is missing; record warnings, extract whatever can be trusted, and keep the app running
- **1.13**: Tags Are Canonical Organization - Bins are just the default `bin` tag namespace; every UI tree, importer, and command must talk to `tag_service`/`tag_assignments` (never `project_settings.bin_hierarchy` or `media_bin_map`); if tag tables are missing the build must fail loudly—absolutely no fallbacks or legacy shims unless Joe says otherwise.

### **1.14 FAIL-FAST ASSERT POLICY (Development Phase)**
- **Default posture**: This codebase is in active development. We prefer **immediate hard failure** over recovery. If a state *should never be possible*, it **must crash** loudly.
- **Use `assert()` aggressively** for invariant violations, including UI/editor invariants (e.g. missing `project_id`, `sequence_id`, `playhead`, “no tracks” when a timeline is active). A “print and continue” is not acceptable for invariants.
- **No silent fallbacks**: Never invent `"default_project"`, `"default_sequence"`, default fps, etc. If required identifiers/metadata are missing, **assert with context**.
- **DB is treated as internal state**: Persisted project DB contents are considered authoritative internal state. Missing rows/metadata that “should exist” are **bugs** and should assert. If the DB is bad from earlier bugs, Joe’s workflow is to **delete/reset the DB** rather than adding shims or recovery paths.
- **Renderer/UI paths may assert**: If invalid render inputs occur (bad colors, impossible geometry, etc.), crash immediately to force a fix. Prefer assert messages that identify the exact bad value and callsite.
- **Make crashes actionable**: Assert messages must include the function/module name and relevant IDs/parameters (sequence_id/track_id/clip_id/command name) so the root cause is obvious.
- **Only soften failures with explicit instruction**: Do not add “graceful degradation”, retries, fallbacks, or compatibility shims unless Joe explicitly asks for production-hardening behavior.

### **2.x Development Standards**
- **2.1**: Clear technical tone, no excessive enthusiasm/emojis
- **2.1.1**: BRUTAL HONESTY - "this is broken" not "could use improvement"
- **2.3**: Verify code architecture before modifying failing tests
- **2.4**: MANDATORY clean builds - no errors or warnings before moving on
- **2.5**: Functions Read Like Algorithms - Functions should read like high-level algorithms that call subfunctions to do the dirty work; NEVER mix high-level logic with low-level implementation details in the same function; Break complex operations into well-named helper functions that handle specific concerns; Main functions should tell the story of WHAT happens, helper functions handle HOW it happens
- **2.6**: Short Functions and Logical File Splitting - Functions should be short and focused on a single responsibility; Files should be relatively short and split into logical units when they grow large; NEVER create monolithic functions that handle multiple concerns; Split large files into cohesive modules based on functionality; Aim for functions that fit on one screen and files that are easy to navigate

- **2.7**: ALWAYS use make -j4 for parallel builds - never use plain make
- **2.8**: Proper attribution: "Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Codex"
- **2.9**: ASSUME FAILURE UNTIL PROVEN OTHERWISE - Default assumption: Nothing is working until specifically verified
- **2.13**: MANDATORY No Fallbacks or Default Values - NEVER use fallback values - they hide errors and mask problems; ALWAYS fail explicitly when required data is missing; NEVER assume defaults - get actual values or error; Surface all errors immediately - no silent failures
- **2.15**: No Backward Compatibility - Default assumption: we DO NOT maintain backward compatibility for schemas, APIs, data stores, or workflows; delete legacy paths as soon as replacements exist; never add shims, migrations, or old-code preservation unless Joe explicitly reverses this rule
- **2.16**: No Shortcuts - NEVER take shortcuts to avoid thorough implementation; Do the complete work required even if it takes longer; Shortcuts lead to broken implementations that take more time to fix than doing it right initially; Always implement the full solution properly
- **2.17**: No Stub Functions - NEVER create stub functions that return dummy values or print messages instead of implementing real functionality; Stub functions mask architectural problems and prevent proper solutions; ALWAYS implement the complete functionality or fix the underlying architecture issue; Stub functions are forbidden - they hide real problems
- **2.18**: FFI vs Business Logic Separation - FFI functions are one-to-one mappings with C++ Qt functions; FFI functions contain parameter validation (not business logic) and no application logic; Business logic functions contain application logic and call FFI functions when they need Qt functionality; NEVER have business logic functions call C++ directly - they must go through FFI functions; NEVER have FFI functions contain business logic - they are pure interfaces to C++
- **2.19**: Complete Tasks Before Building/Testing - NEVER build and test partial work - finish systematic tasks completely first; Building/testing mid-task is a major sidetracking risk that prevents completion; ALWAYS complete entire systematic jobs (like adding validation to ALL functions) before testing; Only build/test when explicitly requested or when systematic work is 100% complete
- **2.20**: Regression Tests First - ALWAYS add a failing regression test BEFORE fixing a bug; PROVE the test fails by temporarily reverting or disabling the fix; ONLY then land the fix and ensure the new test passes; The test suite is more valuable than the implementation
- **2.21**: Statically-Verifiable Approaches - When deciding implementation approaches, strongly prefer designs that allow the compiler to catch errors rather than runtime detection; Change function signatures, add required parameters, use type systems, and leverage static analysis to make impossible states unrepresentable; Avoid approaches that rely on runtime checks to catch implementation mistakes that could be prevented at compile time
- **2.24**: Evidence-Based Claims - ONLY claim success/failure based on observable evidence (screenshots, logs, measurements); Code changes alone are not evidence of fixes; If you cannot observe a difference, state: "I see no change"; Evidence trumps expectations every time
- **2.25**: Document All Debugging Attempts - Failed attempts are valuable progress - document explicitly what didn't work and why; Progress includes: approaches tried, what failed, what was learned; "I tried X but it didn't fix Y" is legitimate progress that guides next steps; Never hide unsuccessful approaches - they prevent repeating failed methods
- **2.28**: No Artificial Progress Inflation - One user request = one todo item, regardless of how many attempts it takes; Do not break single tasks into multiple sub-tasks to mark things "completed"; Progress is measured by user satisfaction, not number of completed attempts; Multiple debugging attempts are iterations within one task, not separate accomplishments; Only mark tasks complete when the user confirms the actual problem is solved
- **2.29**: Snapshot Every BatchCommand - Whenever you queue multiple timeline operations inside a `BatchCommand`, you MUST set `sequence_id` to the active sequence and populate `__snapshot_sequence_ids` with that id. Without this, undo/redo/replay will appear to “do nothing” until a restart because the command manager doesn’t know which sequence to reload. Applies to delete, split, drag/duplicate, ripple, and any future batch operations.
- **2.30**: Persist Track Heights Per Sequence - Every timeline sequence must write its track heights to SQLite (`sequence_track_layouts.track_heights_json`) whenever a header is resized, and that same height map must be reloaded verbatim on init. The most recently modified sequence becomes the project-wide template (`project_settings.track_height_template`), and any brand-new sequence must immediately adopt that template before saving its own layout. No fallbacks: if persistence fails, surface the error rather than silently using defaults.
- **2.31**: Never Change Existing Test Expectations Without Approval - Once a regression test exists, its assertions are canon. You MUST obtain Joe's explicit approval before modifying expected values, pass/fail conditions, or other semantics. If a test fails, fix the implementation or write a new test that demonstrates the correct behavior—do not “adjust” an existing test to match buggy code.
- **2.32**: New Codepaths Require Tests - When you add new behavior, branches, handlers, or invariants, you MUST add tests that exercise the new paths (including edge/failure paths, not just happy paths). For `assert()`-based failure paths, test via `pcall()` and validate the error message is actionable.

### **3.x Design Principles**
- **3.1**: Protocol versioning - support only the current protocol/schema; when formats change, bump the version and migrate forward without keeping the old behavior
- **3.2**: Principle of least amazement - predictable behavior
- **3.3**: Orthogonality - composable commands
- **3.4**: Progressive disclosure - core workflow ≤ 3 clicks
- **3.5**: Fail fast with clear, actionable error messages. While in development mode use asserts to force a stack trace.
- **3.9-3.10**: Complete error propagation with actionable messages
- **3.11**: Discoverable UI - tooltips on all non-obvious controls
- **3.13**: No mysterious disabled controls without explanatory tooltips
- **3.14**: No Marketing Speak - NEVER use marketing terms - no "professional", "enterprise", "robust", "powerful"; USE technical language - clear, direct, factual descriptions only; NO superlatives - describe what IS, not what's "amazing" or "best"; AVOID aspirational language - document verified reality, not goals
- **3.15**: Tag-Driven Organization - Tags are the authoritative organization system; bins are simply the default tag namespace; the tree view is just one visualization of tags, so all organization features must operate on tag namespaces first and render them however the UI requires

## **🎯 ARCHITECTURE REMINDERS (Context for Decisions)**

**You are working in a Scriptable Video Editor Platform where:**
- **Lua scripts** generate ALL interface elements
- **C++ provides** foundation services (commands, errors, widgets, timeline)  
- **Users extend** functionality through Lua, not C++ modification
- **Everything goes through** thin API layer with protection systems

## **🏗️ ARCHITECTURAL REFERENCE - September 2025**

**Critical Understanding**: I am the version of Claude that architected this system. This documentation preserves context continuity for auto-context reload scenarios.

### **Project Structure - Video Editor Architecture**

This is a **Scriptable Video Editor Platform** modeled after Final Cut Pro 7, Resolve, and Premiere, written in Lua with C++ for speed where absolutely necessary.

**Scripting Layer (Lua):**
- `scripts/core/` - Core Lua modules for project/timeline/UI management
- `scripts/ui/` - UI components and FCP7 layout system
- All interface elements generated by Lua scripts, not hardcoded C++

### **Key Architectural Systems**

**2. Qt Interface Architecture** (qt_widgets.cpp and modular bindings):
- **Qt Interface Functions**: `qt_create_widget()`, `qt_set_widget_text()`, `qt_resize_widget()`
  - One-to-one Qt API mappings with parameter validation only
  - Follow qt_verb_noun naming pattern
  - Use FFIParameterValidator for input validation
  - Return userdata with QWIDGET metatable

- **Business Logic Functions**: High-level Lua functions that call Qt interface functions
  - Contain application logic, error handling, state management
  - Never call C++ Qt directly - must go through Qt interface functions

**3. Command Dispatcher System**
- Universal command system with undo/redo support
- Keyboard/MIDI controller mapping

**4. Timeline Architecture**
- Event-sourced with complete history tracking
- Frame-accurate editing
- TimelineDatabase holds all objects by stable IDs
- Sequences contain Tracks containing TimelineInstances of MediaItems

**5. Lua Integration**
- Hot reloading support for script development
- ResourcePaths system for cross-directory execution
- Error propagation through ErrorContext system
- Command registration bridge between C++ and Lua

### **Scripting and Lua Integration Details**:

**Error System** (scripts/core/error_system.lua):
- Comprehensive error categories: qt_widget, inspector, metadata, command
- Error severity levels: critical, error, warning, info
- Context stack building for error propagation
- Remediation suggestion system

**Lua Module Architecture**:
- `scripts/core/ui_toolkit.lua` - High-level UI construction functions
- `scripts/core/timeline_api.lua` - Timeline operations and playback control
- `scripts/core/project.lua` - Project management integration
- `scripts/core/window_manager.lua` - Window layout and FCP7 UI system

**Resource Management**:
- `ResourcePaths` class for cross-directory execution support
- Automatic scripts directory detection relative to executable
- Lua package.path configuration for require() module loading

### **Integration Patterns**

**Lua to C++ Call Pattern**:
1. Lua script calls Qt interface function (e.g., qt_create_widget)
2. FFIParameterValidator validates all inputs
3. Qt interface function performs one-to-one Qt API mapping
4. Returns userdata with proper metatable for Lua access
5. Business logic in Lua handles application-specific operations

**Error Propagation Pattern**:
1. All errors include context, suggestions, and technical details


## **🚫 ABSOLUTE PROHIBITIONS**

- Creating new error handling systems (Rule #2)
- Direct Qt widget manipulation outside bindings (Rule #3)
- Manual memory management (Rule #3)
- Ad-hoc command patterns (Rule #3)
- Multiple implementations of the same functionality (Rule #4)
- Bypassing existing validation systems (Rule #1)
- **Using fallback values or defaults** - always fail explicitly (Rule #5)
- **Silent error handling** - all errors must be surfaced (Rule #5)
- **Hardcoding constants** - use symbolic constants (Rule #6)
- **Maintaining backward compatibility** without explicitly asking the user first (Rule #7)
- **Aspirational documentation** - only document verified reality (Rule 0.1)
- **Skipping TodoWrite updates** - track all task progress (Rule 0)
- **Wrong commit attribution** - use Joe's format (Rule 2.8)
- **Ignoring build warnings/errors** - must have clean builds (Rule 2.4)

---

## **✅ SUCCESS PATTERN**

1. **Understand** → Study existing implementation first
2. **Extend** → Add to existing patterns, don't replace
3. **Test** → Verify integration with existing systems
4. **Verify** → Confirm no competing implementations created

**Remember**: Your efficiency comes from leveraging the robust systems already built, not from avoiding their "overhead".
- NEVER use marketing speak. ALWAYS be truthful
- always do a push after a ci
- don't mark tasks complete until i agree
- When asked to fix a bug, first add a regression test that fails. Only after demonstrating the failure may you implement the fix and verify the test passes.
