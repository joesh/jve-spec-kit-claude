# src/

This directory contains all runtime source code for JVE.

The application is implemented primarily in Lua. This file documents structure only.
Behavioral intent, invariants, and workflows are documented under `docs/`.

## Layout

### src/lua/
Primary application logic.

- core/ — commands, state management, persistence primitives
- models/ — domain models and invariants
- ui/ — UI composition and interaction logic
- qt_bindings/ — Lua ↔ host/UI bindings (no business logic)
- inspectable/ — inspection and reflection systems
- importers/ — external format ingestion
- media/ — media discovery and metadata
- bug_reporter/ — Lua-side bug capture integration

### src/bug_reporter/
Host-side support for bug reporting and capture.
