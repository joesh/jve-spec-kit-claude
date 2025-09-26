
# Implementation Plan: Video Editor M1 Foundation

**Branch**: `001-editor-project-v1` | **Date**: 2025-09-26 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/Users/joe/Local/jve-spec-kit-claude/specs/001-editor-project-v1/spec.md`

## Execution Flow (/plan command scope)
```
1. Load feature spec from Input path
   → If not found: ERROR "No feature spec at {path}"
2. Fill Technical Context (scan for NEEDS CLARIFICATION)
   → Detect Project Type from file system structure or context (web=frontend+backend, mobile=app+api)
   → Set Structure Decision based on project type
3. Fill the Constitution Check section based on the content of the constitution document.
4. Evaluate Constitution Check section below
   → If violations exist: Document in Complexity Tracking
   → If no justification possible: ERROR "Simplify approach first"
   → Update Progress Tracking: Initial Constitution Check
5. Execute Phase 0 → research.md
   → If NEEDS CLARIFICATION remain: ERROR "Resolve unknowns"
6. Execute Phase 1 → contracts, data-model.md, quickstart.md, agent-specific template file (e.g., `CLAUDE.md` for Claude Code, `.github/copilot-instructions.md` for GitHub Copilot, `GEMINI.md` for Gemini CLI, `QWEN.md` for Qwen Code or `AGENTS.md` for opencode).
7. Re-evaluate Constitution Check section
   → If new violations: Refactor design, return to Phase 1
   → Update Progress Tracking: Post-Design Constitution Check
8. Plan Phase 2 → Describe task generation approach (DO NOT create tasks.md)
9. STOP - Ready for /tasks command
```

**IMPORTANT**: The /plan command STOPS at step 7. Phases 2-4 are executed by other commands:
- Phase 2: /tasks command creates tasks.md
- Phase 3-4: Implementation execution (manual or via tools)

## Summary
Build a usable editor skeleton demonstrating the core model-UI loop: Project Browser, Timeline, Inspector panel, and Viewers with SQLite persistence, deterministic command system, and single-file (.jve) project format. Foundation for hackable, script-forward video editing platform.

## Technical Context
**Language/Version**: C++ (Qt6) + Lua (LuaJIT) hybrid architecture  
**Primary Dependencies**: Qt6 (UI framework), LuaJIT (scripting), SQLite (persistence)  
**Storage**: SQLite with deterministic command logging and atomic snapshots  
**Testing**: Qt Test framework + Lua test harness for script components  
**Target Platform**: Cross-platform desktop (macOS, Linux, Windows)
**Project Type**: single - desktop application with integrated panels  
**Performance Goals**: Real-time UI updates, <16ms timeline redraws, deterministic replay  
**Constraints**: Single-file projects, no WAL/SHM files, script-forward architecture  
**Scale/Scope**: Professional editor foundation, 4-panel UI, command-driven operations

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**I. Library-First Architecture**: ✅ Feature implemented as standalone library  
**II. CLI Interface Standard**: ✅ Exposes CLI with stdin/stdout protocol  
**III. Test-First Development**: ✅ TDD approach with tests written first  
**IV. Documentation-Driven Specifications**: ✅ Complete specification before implementation  
**V. Template-Based Consistency**: ✅ Follows established templates

## Project Structure

### Documentation (this feature)
```
specs/[###-feature]/
├── plan.md              # This file (/plan command output)
├── research.md          # Phase 0 output (/plan command)
├── data-model.md        # Phase 1 output (/plan command)
├── quickstart.md        # Phase 1 output (/plan command)
├── contracts/           # Phase 1 output (/plan command)
└── tasks.md             # Phase 2 output (/tasks command - NOT created by /plan)
```

### Source Code (repository root)
<!--
  ACTION REQUIRED: Replace the placeholder tree below with the concrete layout
  for this feature. Delete unused options and expand the chosen structure with
  real paths (e.g., apps/admin, packages/something). The delivered plan must
  not include Option labels.
-->
```
src/
├── core/
│   ├── models/           # SQLite schema, entities (Project, Sequence, Clip)
│   ├── commands/         # Command system, deterministic operations
│   └── persistence/      # SQLite persistence, atomic saves, replay
├── ui/
│   ├── panels/          # Project Browser, Timeline, Inspector, Viewers
│   ├── widgets/         # Custom controls, tri-state inputs
│   └── dialogs/         # Modal interactions
├── lua/
│   ├── runtime/         # LuaJIT integration, script loading
│   ├── api/             # Lua-to-C++ bindings
│   └── scripts/         # Default panel behaviors, extensibility
└── cli/                 # Command-line tools for debugging

tests/
├── contract/            # Command API contract tests
├── integration/         # Panel integration, workflow tests
├── unit/               # Model validation, command determinism
└── lua/                # Script runtime testing
```

**Structure Decision**: Single desktop application with C++/Qt6 + Lua hybrid architecture. Core models and persistence in C++ for performance, UI panels as Qt6 widgets, Lua for scripting and extensibility. Test structure supports contract testing for command API, integration testing for panel workflows, and unit testing for deterministic behavior.

## Phase 0: Outline & Research
1. **Extract unknowns from Technical Context** above:
   - For each NEEDS CLARIFICATION → research task
   - For each dependency → best practices task
   - For each integration → patterns task

2. **Generate and dispatch research agents**:
   ```
   For each unknown in Technical Context:
     Task: "Research {unknown} for {feature context}"
   For each technology choice:
     Task: "Find best practices for {tech} in {domain}"
   ```

3. **Consolidate findings** in `research.md` using format:
   - Decision: [what was chosen]
   - Rationale: [why chosen]
   - Alternatives considered: [what else evaluated]

**Output**: research.md with all NEEDS CLARIFICATION resolved

## Phase 1: Design & Contracts
*Prerequisites: research.md complete*

1. **Extract entities from feature spec** → `data-model.md`:
   - Entity name, fields, relationships
   - Validation rules from requirements
   - State transitions if applicable

2. **Generate API contracts** from functional requirements:
   - For each user action → endpoint
   - Use standard REST/GraphQL patterns
   - Output OpenAPI/GraphQL schema to `/contracts/`

3. **Generate contract tests** from contracts:
   - One test file per endpoint
   - Assert request/response schemas
   - Tests must fail (no implementation yet)

4. **Extract test scenarios** from user stories:
   - Each story → integration test scenario
   - Quickstart test = story validation steps

5. **Update agent file incrementally** (O(1) operation):
   - Run `.specify/scripts/bash/update-agent-context.sh claude`
     **IMPORTANT**: Execute it exactly as specified above. Do not add or remove any arguments.
   - If exists: Add only NEW tech from current plan
   - Preserve manual additions between markers
   - Update recent changes (keep last 3)
   - Keep under 150 lines for token efficiency
   - Output to repository root

**Output**: data-model.md, /contracts/*, failing tests, quickstart.md, ui-layout-spec.md, agent-specific file

## Phase 2: Task Planning Approach
*This section describes what the /tasks command will do - DO NOT execute during /plan*

**Task Generation Strategy**:
- Load `.specify/templates/tasks-template.md` as base
- Generate from contracts: command-api.yaml → command system tests, project-api.yaml → project management tests, selection-api.yaml → selection system tests
- Generate from data model: 8 entities → 8 model creation tasks [P], relationship validation tasks
- Generate from ui-layout-spec.md: 4 panel widgets → 4 UI implementation tasks, professional theming task
- Generate from quickstart: 7 test scenarios → 7 integration test tasks
- Implementation tasks: Core models → Command system → UI panels (with specific layouts) → Integration

**Ordering Strategy**:
- TDD order: Contract tests → Integration tests → Model implementation → UI implementation
- Dependency order: SQLite schema → Core models → Command system → UI panels → Keyboard shortcuts
- Parallel execution: Model classes [P], Panel widgets [P], Contract tests [P]
- Sequential: Command system depends on models, UI panels depend on command system

**Estimated Output**: 35-40 numbered, ordered tasks covering:
- Setup & Infrastructure (3-4 tasks)
- Contract Tests (8-10 tasks) [P]
- Core Models (8 tasks) [P] 
- Command System (6-8 tasks)
- UI Panels (10-12 tasks)
- Integration & Polish (4-6 tasks)

**IMPORTANT**: This phase is executed by the /tasks command, NOT by /plan

## Phase 3+: Future Implementation
*These phases are beyond the scope of the /plan command*

**Phase 3**: Task execution (/tasks command creates tasks.md)  
**Phase 4**: Implementation (execute tasks.md following constitutional principles)  
**Phase 5**: Validation (run tests, execute quickstart.md, performance validation)

## Complexity Tracking
*Fill ONLY if Constitution Check has violations that must be justified*

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |


## Progress Tracking
*This checklist is updated during execution flow*

**Phase Status**:
- [x] Phase 0: Research complete (/plan command)
- [x] Phase 1: Design complete (/plan command)
- [x] Phase 2: Task planning complete (/plan command - describe approach only)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented (none required)

---
*Based on Constitution v1.0.0 - See `.specify/memory/constitution.md`*
