# Research: Video Editor M1 Foundation

## Qt6 + LuaJIT Integration

**Decision**: Use Qt6 with LuaJIT embedded runtime for hybrid C++/Lua architecture
**Rationale**: 
- Qt6 provides mature cross-platform UI framework with native performance
- LuaJIT offers high-performance scripting with FFI for seamless C++ integration
- Established pattern in game engines and media applications
- Enables script-forward architecture without performance penalty

**Alternatives considered**:
- Pure C++/Qt6: Rejected due to lack of extensibility/hackability requirements
- Electron + Node.js: Rejected due to performance constraints for real-time editing
- Python/PySide6: Rejected due to GIL limitations and deployment complexity

## SQLite Command Logging Pattern

**Decision**: SQLite with append-only command log + periodic snapshots for deterministic replay
**Rationale**:
- Proven pattern in event sourcing and collaborative editing systems
- SQLite ACID guarantees ensure data integrity
- Deterministic replay enables robust debugging and collaboration
- Single-file constraint met with embedded SQLite

**Alternatives considered**:
- JSON file persistence: Rejected due to lack of transactional guarantees
- PostgreSQL: Rejected due to single-file project requirement
- Custom binary format: Rejected due to complexity and lack of SQL query capability

## UI Panel Architecture

**Decision**: Qt6 QDockWidget system with custom QWidget panels
**Rationale**:
- Native dockable panel system matches professional editor UX expectations
- Qt6 model/view architecture supports multi-selection and tri-state controls
- Custom widgets enable specialized timeline and inspector behaviors
- Established pattern in professional applications (DaVinci Resolve, etc.)

**Alternatives considered**:
- Web-based panels (QtWebEngine): Rejected due to performance and integration complexity
- Pure QML: Rejected due to C++ model integration complexity
- Third-party docking framework: Rejected due to Qt6 native capabilities

## Testing Strategy

**Decision**: Multi-layered testing with Qt Test framework + Lua test harness
**Rationale**:
- Qt Test provides native support for UI testing and signal/slot verification
- Contract testing ensures command API determinism across implementations
- Integration testing validates panel workflows and user scenarios
- Lua test harness enables script behavior validation

**Alternatives considered**:
- Google Test: Rejected in favor of Qt-native testing framework
- Manual testing only: Rejected due to constitutional TDD requirement
- BDD frameworks: Rejected due to integration complexity with Qt6/Lua

## Performance Considerations

**Decision**: 60fps UI with <16ms timeline redraws, integer-only tick arithmetic
**Rationale**:
- Professional editors require smooth real-time feedback during editing
- Integer ticks avoid floating-point precision issues in long-form content
- Qt6 graphics view framework optimized for large-scale timeline visualization
- Lua JIT compilation ensures script performance doesn't degrade UI responsiveness

**Alternatives considered**:
- 30fps target: Rejected as insufficient for professional editing feedback
- Floating-point timecode: Rejected due to precision accumulation in long sequences
- Canvas-based timeline: Rejected in favor of Qt6 native graphics performance

## Development Workflow Integration

**Decision**: Constitutional compliance with TDD, library-first, CLI-enabled design
**Rationale**:
- Each panel implemented as testable library component
- Command-line tools enable automated testing and debugging workflows
- Script-forward architecture aligns with hackability requirements
- Test-first approach ensures reliable foundation for complex editor behaviors

**Alternatives considered**:
- Monolithic implementation: Rejected due to constitutional library-first requirement
- GUI-only debugging: Rejected due to CLI interface constitutional requirement
- Implementation-first approach: Rejected due to constitutional TDD mandate

## Cross-Platform Considerations

**Decision**: Qt6 native builds for macOS, Linux, Windows with consistent SQLite backend
**Rationale**:
- Qt6 provides mature cross-platform abstraction
- SQLite ensures consistent data format across platforms  
- Native builds avoid performance penalties of interpreted/VM solutions
- Professional editors require native OS integration

**Alternatives considered**:
- Web application: Rejected due to performance requirements
- Platform-specific implementations: Rejected due to maintenance complexity
- Single platform focus: Rejected due to user base requirements