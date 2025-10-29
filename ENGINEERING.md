# Claude Code Instructions - JVE (Joe's Video Editor)

## **🔧 DEVELOPMENT RULES**

### **0. Todo Management & Session Continuity**
- **ALWAYS use TodoWrite tool** for real-time task tracking
- **UPDATE immediately** when starting/completing/discovering tasks
- **CHECK todo list FIRST** before asking what's next
- **ONE task in_progress** at a time
- **Mark in_progress BEFORE starting, completed IMMEDIATELY after finishing**

### **0.1 MANDATORY Documentation Honesty**
- **NEVER write "complete/ready/working" without personal verification**
- **NO aspirational language** - describe what IS, not what should be
- **LIST broken/incomplete items explicitly**
- **BEFORE updating status docs**: Run tests AND verify functionality
- **ACCOUNTABILITY**: Every claim must be verifiable

### **0.2 Context Preservation for Auto-Compact**
- **ALWAYS update CLAUDE_CONTEXT.md** as you learn critical architectural details
- **DOCUMENT decisions and discoveries** immediately - don't rely on chat memory
- **INCLUDE current bug status** and fix progress in context file
- **ADD breakthrough insights** about codebase design and user preferences
- **PRESERVE context continuity** - assume future Claude has no memory of this session

### **1.x Core Development Standards**
- **1.1**: Comprehensive error handling upfront (not iterative debugging)
- **1.2**: Test before assuming - validate everything incrementally
- **1.3**: Don't change what's working without proven need
- **1.4**: Modular architecture - single responsibility, clean separation
- **1.5**: MANDATORY data-driven config - NO hardcoded UI styles/schemas/lists
- **1.6**: MANDATORY universal state persistence - all widgets inherit PersistentWidget
- **1.7**: Real-time session logging - update CURRENT_SESSION_STATUS.md after every task
- **1.8**: Always analyze existing patterns before implementing - Study existing code patterns before writing any new code; find similar implementations; use established conventions; document pattern decisions
- **1.9**: Respect the Architecture - NEVER bypass existing abstractions (error system, widget registry, Lua API); ALWAYS use existing patterns - don't invent new approaches; If unsure, ask - don't guess and implement
- **1.10**: Stay in Your Layer - Lua scripts call Qt bindings - never direct Qt; Use widget registry RAII handles - never manual memory management; Go through command dispatcher - never direct function calls
- **1.11**: Never Change Architecture Without Permission - NEVER modify function calling patterns without explicit user approval; NEVER reorganize modules or interfaces without user consultation; NEVER replace one system with another without user decision; ALWAYS ask first before changing how components interact
- **1.12**: External inputs must NEVER crash the system - all imported data (XML, DB, files) must be validated; degrade gracefully when metadata is missing; record warnings, extract whatever can be trusted, and keep the app running

### **2.x Development Standards**
- **2.1**: Clear technical tone, no excessive enthusiasm/emojis
- **2.1.1**: BRUTAL HONESTY - "this is broken" not "could use improvement"
- **2.2**: Zero-tolerance testing - ALL tests must pass before proceeding
- **2.3**: Verify code architecture before modifying failing tests
- **2.4**: MANDATORY clean builds - no errors or warnings before moving on
- **2.5**: MANDATORY milestone commits - never leave progress uncommitted
- **2.7**: Auto-approved dev commands (make/cmake/git status) - execute immediately
- **2.7.1**: ALWAYS use make -j4 for parallel builds - never use plain make
- **2.8**: Proper attribution: "Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude"
- **2.9**: ASSUME FAILURE UNTIL PROVEN OTHERWISE - Default assumption: Nothing is working until specifically verified
- **2.10**: VERIFY THAT YOU DIDN'T BREAK ANYTHING - Always test existing functionality after making changes
- **2.11**: Use decimal notation for rule numbering with logical categories - Rules numbered within categories (0.x Todo/Documentation, 1.x Core Development, 2.x Development Standards, 3.x Design Principles); count existing rules in category first; never renumber existing rules as they're referenced in commit messages
- **2.12**: Follow the Error System - ALWAYS propagate errors through ErrorContext system; NEVER write ad-hoc error handling; EVERY operation must return success/error state
- **2.13**: No Fallbacks or Default Values - NEVER use fallback values - they hide errors and mask problems; ALWAYS fail explicitly when required data is missing; NEVER assume defaults - get actual values or error; Surface all errors immediately - no silent failures
- **2.14**: No Hardcoded Constants - NEVER hardcode magic numbers - create symbolic constants instead; CENTRALIZE all constants in dedicated header/module files; USE meaningful names that explain what the constant represents; DOCUMENT the purpose and units of each constant
- **2.15**: No Backward Compatibility Without Permission - NEVER maintain backward compatibility without explicitly asking the user first; ALWAYS remove deprecated APIs immediately when creating new ones; NO legacy global exports - use proper module returns only; BREAK things cleanly rather than maintain confusing dual APIs
- **2.16**: No Shortcuts - NEVER take shortcuts to avoid thorough implementation; Do the complete work required even if it takes longer; Shortcuts lead to broken implementations that take more time to fix than doing it right initially; Always implement the full solution properly
- **2.17**: No Stub Functions - NEVER create stub functions that return dummy values or print messages instead of implementing real functionality; Stub functions mask architectural problems and prevent proper solutions; ALWAYS implement the complete functionality or fix the underlying architecture issue; Stub functions are forbidden - they hide real problems
- **2.18**: FFI vs Business Logic Separation - FFI functions are one-to-one mappings with C++ Qt functions; FFI functions contain parameter validation (not business logic) and no application logic; Business logic functions contain application logic and call FFI functions when they need Qt functionality; NEVER have business logic functions call C++ directly - they must go through FFI functions; NEVER have FFI functions contain business logic - they are pure interfaces to C++
- **2.19**: Complete Tasks Before Building/Testing - NEVER build and test partial work - finish systematic tasks completely first; Building/testing mid-task is a major sidetracking risk that prevents completion; ALWAYS complete entire systematic jobs (like adding validation to ALL functions) before testing; Only build/test when explicitly requested or when systematic work is 100% complete
- **2.20**: Regression Tests First - ALWAYS add a failing regression test before fixing a bug; PROVE the test fails by temporarily reverting or disabling the fix; ONLY then land the fix and ensure the new test passes; The test suite is more valuable than the implementation
- **2.20**: GUI Application Debugging Technique - When testing GUI apps that hang due to debug messages: (1) Run without timeout, (2) Monitor log file size with `watch -n 1 'wc -l build/jve.log'`, (3) When log stops growing, take screenshot of desktop, (4) Kill the application, (5) Analyze log and screenshot to determine actual success/failure; This avoids timeout issues while providing complete verification of GUI state
- **2.21**: Compiler-Verifiable Approaches - When deciding implementation approaches, strongly prefer designs that allow the compiler to catch errors rather than runtime detection; Change function signatures, add required parameters, use type systems, and leverage static analysis to make impossible states unrepresentable; Avoid approaches that rely on runtime checks to catch implementation mistakes that could be prevented at compile time
- **2.22**: Careful Code Modifications - When modifying code, be extremely careful with batch operations like sed; Only use sed if you're absolutely certain it will target exactly the right places and won't cause unintended changes; For all other cases, make changes one by one using precise Edit operations; Batch text replacements on code are dangerous and can break functionality in subtle ways
- **2.23**: JVE Testing Methodology - When testing jve, always use this complete workflow: 1) Run jve in background with log file: `./jve --test-fcp7-layout > build/test_name.log 2>&1 &`, 2) Monitor log file size until stable: use while loop to detect when file stops growing for 3+ consecutive checks, 3) Take screenshot for visual verification of actual GUI state, 4) Kill jve immediately after screenshot: `pkill -f jve` to free system resources, 5) Analyze both log content AND screenshot to determine what's actually working vs just claimed in logs
- **2.24**: Evidence-Based Claims - ONLY claim success/failure based on observable evidence (screenshots, logs, measurements); Code changes alone are not evidence of fixes; If you cannot observe a difference, state: "I see no change"; Evidence trumps expectations every time
- **2.25**: Document All Debugging Attempts - Failed attempts are valuable progress - document explicitly what didn't work and why; Progress includes: approaches tried, what failed, what was learned; "I tried X but it didn't fix Y" is legitimate progress that guides next steps; Never hide unsuccessful approaches - they prevent repeating failed methods
- **2.26**: Functions Read Like Algorithms - Functions should read like high-level algorithms that call subfunctions to do the dirty work; NEVER mix high-level logic with low-level implementation details in the same function; Break complex operations into well-named helper functions that handle specific concerns; Main functions should tell the story of WHAT happens, helper functions handle HOW it happens
- **2.27**: Short Functions and Logical File Splitting - Functions should be short and focused on a single responsibility; Files should be relatively short and split into logical units when they grow large; NEVER create monolithic functions that handle multiple concerns; Split large files into cohesive modules based on functionality; Aim for functions that fit on one screen and files that are easy to navigate
- **2.28**: No Artificial Progress Inflation - One user request = one todo item, regardless of how many attempts it takes; Do not break single tasks into multiple sub-tasks to mark things "completed"; Progress is measured by user satisfaction, not number of completed attempts; Multiple debugging attempts are iterations within one task, not separate accomplishments; Only mark tasks complete when the user confirms the actual problem is solved

### **3.x Design Principles**
- **3.1**: Protocol versioning - backward compatibility for all persistent artifacts
- **3.2**: Principle of least amazement - predictable behavior
- **3.3**: Orthogonality - composable commands
- **3.4**: Progressive disclosure - core workflow ≤3 clicks
- **3.5**: Fail fast with clear, actionable error messages
- **3.9-3.10**: Complete error propagation with actionable messages
- **3.11**: Discoverable UI - tooltips on all non-obvious controls
- **3.13**: No mysterious disabled controls without explanatory tooltips
- **3.14**: No Marketing Speak - NEVER use marketing terms - no "professional", "enterprise", "robust", "powerful"; USE technical language - clear, direct, factual descriptions only; NO superlatives - describe what IS, not what's "amazing" or "best"; AVOID aspirational language - document verified reality, not goals

---

## **⚡ SESSION MODE: One Focus At A Time**

**Before starting ANY work, Claude must:**

1. **State the ONE architectural pattern** you'll be working within
2. **Confirm you understand the existing implementation** 
3. **Commit to extending, not replacing** existing code

**Example**:
> "I will work within the ErrorContext system, extending the existing widget parenting validation. I will NOT create new error handling approaches."

---

## **📋 IMPLEMENTATION PROTOCOL**

### **Step 1: Integration Check**
- [ ] Does this work WITH existing code or AGAINST it?
- [ ] Am I using the established patterns or inventing new ones?
- [ ] Will this create competing implementations?

### **Step 2: Error-First Implementation** 
- [ ] Started with error context setup (Rule 1.1)
- [ ] All operations return ErrorContext results (Rule #2)
- [ ] No silent failures or exceptions (Rule #5)
- [ ] No fallback values or defaults (Rule #5)
- [ ] Update TodoWrite with task progress (Rule 0)
- [ ] Document honestly - no aspirational claims (Rule 0.1)

### **Step 3: Verification**
- [ ] Clean build with no errors or warnings (Rule 2.4)
- [ ] Tests pass (Rule 2.2 - zero tolerance testing)
- [ ] No new competing patterns introduced
- [ ] Follows existing code style exactly
- [ ] MANDATORY milestone commit if significant work completed (Rule 2.5)
- [ ] Use proper attribution format in commits (Rule 2.8)

---

## **🎯 ARCHITECTURE REMINDERS (Context for Decisions)**

**You are working in a Scriptable Video Editor Platform where:**
- **Lua scripts** generate ALL interface elements
- **C++ provides** foundation services (commands, errors, widgets, timeline)  
- **Users extend** functionality through Lua, not C++ modification
- **Everything goes through** thin API layer with protection systems

**Key Systems Already Built:**
- `ErrorContext` - Rich error propagation with auto-fix suggestions
- `WidgetRegistry` - RAII resource management for all Qt widgets
- `CommandDispatcher` - Universal command system with undo/redo
- `QtLuaBindings` - Thin API for Qt widget creation from Lua with REGISTRY_REF metatable system
- `ScriptableMainWindow` - Object-oriented window management for FCP7 layout system
- `EventJournal` - Event-sourced timeline with complete history

**Your Job**: Extend these systems, never replace them.

## **🔄 RESTORATION HISTORY (September 2025)**

**Critical Incident**: Commit `7d6582e` "Implement Phase 2 RAII Resource Management" accidentally deleted the working ScriptableMainWindow integration during RAII refactoring, breaking `create_main_window` functionality.

**Resolution**: Successfully restored from stash@{1} which contained:
- Complete REGISTRY_REF metatable preservation system
- All 11 ScriptableMainWindow function implementations  
- Object-oriented Lua API with userdata preservation
- Full FCP7 4-window layout functionality

**Build System Fixes (September 2025)**:
- Fixed hardcoded path references in cmake files (`/Users/joe/Local/final-cut-pro-7-clone` → `/Users/joe/Local/jve`)
- Resolved ScriptableWidget/ScriptableTimeline linker errors by adding missing `src/ui/scriptable_window.cpp` to all executables using `qt_lua_bindings.cpp`
- Build now completes cleanly at 100% without undefined symbol errors
- **Fixed jve Output Directory**: Added `RUNTIME_OUTPUT_DIRECTORY` property so `jve` executable automatically builds to project root instead of build directory

**Lesson**: Always preserve working functionality during architectural changes. The REGISTRY_REF system and ScriptableMainWindow integration were critical to the FCP7 layout and should not be modified without extensive testing.

---

## **🏗️ ARCHITECTURAL REFERENCE - September 2025**

**Critical Understanding**: I am the version of Claude that architected this system. This documentation preserves context continuity for auto-context reload scenarios.

### **Project Structure - Video Editor Architecture**

This is a **Scriptable Video Editor Platform** modeled after Final Cut Pro 7, with core C++ foundation and Lua-driven UI/features:

**Core Foundation (C++):**
- `src/project/` - Project management system with JSON serialization
- `src/timeline/` - Event-sourced timeline with frame-accurate editing
- `src/scripting/` - Lua integration with modular Qt bindings  
- `src/core/` - Foundation services (errors, resource paths, widgets)

**Scripting Layer (Lua):**
- `scripts/core/` - Core Lua modules for project/timeline/UI management
- `scripts/ui/` - UI components and FCP7 layout system
- All interface elements generated by Lua scripts, not hardcoded C++

### **Phase Restoration History (September 2025)**

**Phase 2 Completed**: TODO Stub Elimination (Rule 2.17)
- Implemented complete business logic for 39 TODO violations
- All systems now have functional implementation across video editor
- Project management, GUI framework, playback engine, metadata integration complete

**Phase 3 Completed**: Qt Interface vs Business Logic Separation (Rule 2.18)
- Systematic function renaming to qt_verb_noun pattern (e.g., `qt_set_widget_text`)
- Separated Qt interface functions (parameter validation only) from business logic
- Applied user corrections: "Qt" not "FFI", proper qt_verb_noun naming

### **Key Architectural Systems**

**1. Project Management System** (project_types.h/cpp):
```cpp
namespace project {
  class ProjectManager {
    static ProjectManager& instance();
    std::shared_ptr<Project> createProject(const QString& name);
    std::shared_ptr<Project> getActiveProject();
    void setActiveProject(std::shared_ptr<Project> project);
  };
  
  class Project {
    ProjectId getId() const;
    QString getName() const;
    const ProjectSettings& getSettings() const;
    MediaPool& getMediaPool();
  };
  
  class MediaPool {
    BinId createBin(const QString& name, BinId parent_id = 0);
    Bin* getBin(BinId bin_id);
  };
}
```

**2. Qt Interface Architecture** (qt_widgets.cpp and modular bindings):
- **Qt Interface Functions**: `qt_create_widget()`, `qt_set_widget_text()`, `qt_resize_widget()`
  - One-to-one Qt API mappings with parameter validation only
  - Follow qt_verb_noun naming pattern
  - Use FFIParameterValidator for input validation
  - Return userdata with QWIDGET metatable

- **Business Logic Functions**: High-level Lua functions that call Qt interface functions
  - Contain application logic, error handling, state management
  - Never call C++ Qt directly - must go through Qt interface functions

**3. Command Dispatcher System** (command_dispatcher.h):
- Universal command system with undo/redo support
- Keyboard/MIDI controller mapping
- Identical registration for C++ and Lua commands
- Parameters support: STRING, INTEGER, DOUBLE, BOOLEAN, OBJECT, REGISTRY_REF

**4. Timeline Architecture** (core_types.h):
- Event-sourced with complete history tracking
- Frame-accurate editing with FrameTime/FrameDuration types
- TimelineDatabase holds all objects by stable IDs
- Sequences contain Tracks containing TimelineInstances of MediaItems

**5. Lua Integration** (lua_engine.h):
- Hot reloading support for script development
- ResourcePaths system for cross-directory execution
- Error propagation through ErrorContext system
- Command registration bridge between C++ and Lua

**6. Resource Management**:
- WidgetRegistry with RAII handles for Qt widgets
- REGISTRY_REF metatable system for userdata preservation
- ResourcePaths for cross-directory script loading

### **Metadata Schema System** (metadata_schemas.h/cpp):
- JSON-driven metadata field definitions matching Premiere Pro standards
- Support for XMP, EXIF, IPTC, Dublin Core metadata standards
- MetadataField structure with validation, defaults, tooltips
- Schema loading from JSON files for data-driven configuration
- Integration with clip_system.h for comprehensive media metadata

### **Qt Interface Architecture Details** (qt_core.h and modular bindings):

**FFI Parameter Validation System**:
```cpp
enum class FFIArgType { WIDGET, STRING, INTEGER, POSITIVE_INTEGER, BOOLEAN, LAYOUT };
struct FFIArgSpec { FFIArgType type; FFIParamName name; int min_value; };
class FFIParameterValidator {
  static ValidationResult validate(lua_State* L, const char* function_name,
                                 std::initializer_list<FFIArgSpec> arg_specs);
};
```

**Modular Qt Bindings Architecture**:
- `qt_widgets.h/cpp` - Widget creation/manipulation (qt_create_widget, qt_set_widget_text)
- `qt_layouts.h/cpp` - Layout management (qt_create_layout, qt_add_layout_child)
- `qt_graphics.h/cpp` - Graphics scene/view system for timeline rendering
- `qt_controls.h/cpp` - Form controls (buttons, inputs, combos)
- `qt_windows.h/cpp` - Window management and docking
- `qt_core.h` - Common infrastructure and parameter validation

**Lua Metatable System**:
- Direct userdata pointers (no wrapper objects)
- Type-safe metatables: JVE.QWidget, JVE.QMainWindow, JVE.QLayout
- REGISTRY_REF system for widget preservation across Lua calls

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

### **Critical Naming Conventions**

**C++ Functions**: camelCase (`createSequence`, `getWidget`, `registerWidget`)
**Qt Interface Functions**: qt_verb_noun (`qt_create_widget`, `qt_set_widget_text`)
**Lua Modules**: snake_case filenames, proper module returns (no global exports)
**FFI Parameters**: Type-safe constants (PARAM_WIDGET, PARAM_TEXT, PARAM_WIDTH)

### **Build System Status**
- CMakeLists.txt: Fixed hardcoded paths, added missing source files
- jve executable: Auto-builds to project root via RUNTIME_OUTPUT_DIRECTORY
- All bindings: Modular Qt bindings architecture (qt_widgets, qt_layouts, qt_graphics, etc.)
- Clean builds: No undefined symbols, all tests compile

### **Integration Patterns**

**Lua to C++ Call Pattern**:
1. Lua script calls Qt interface function (e.g., qt_create_widget)
2. FFIParameterValidator validates all inputs
3. Qt interface function performs one-to-one Qt API mapping
4. Returns userdata with proper metatable for Lua access
5. Business logic in Lua handles application-specific operations

**Error Propagation Pattern**:
1. C++ operations use ErrorContext system for structured errors
2. Lua functions use error_system.safe_call() for error handling
3. LuaErrorHelper bridges FFI errors to ErrorContext
4. All errors include context, suggestions, and technical details

---

## **📝 CODE CONVENTIONS**

### **Naming Convention: camelCase**
- **C++ Functions**: `createSequence()`, `importMedia()`, `getWidget()`
- **Timeline API**: `beginTx()`, `commitTx()`, `replayToHead()`
- **Database API**: `getInstance()`, `getSequence()`, `createTrack()`
- **Event System**: `appendEvent()`, `getTimestampUs()`, `applyEvent()`
- **Qt Bindings**: `getWidget()`, `registerWidget()`, `clearRegistry()`

**Migration Note**: All snake_case functions converted to camelCase (2025-09-02)

---

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
