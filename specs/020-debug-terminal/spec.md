# Feature Specification: Debug Terminal — Lua REPL over Unix socket

**Feature Branch**: `020-debug-terminal`
**Created**: 2026-05-20
**Status**: Draft (initial primitives landed in this session; integration-test usage in 020 Phase 1)

---

## Why this spec exists

JVE's current test infrastructure forces every test to either (a) run in `--test` mode with a stub-heavy `command_manager.execute_interactive("X", …)` invocation (the "fiction" pattern — bypasses keymap → QShortcut → focus cascade), or (b) require a full editor restart per iteration. Neither catches the regression class where the dispatch chain *upstream* of the executor breaks (proven 2026-05-20: `E / plain Comma / plain Period` silently dead in the running app while 60+ unit tests for ExtendEdit/NudgeSelection executors were green; the QTest::keyClick / CGEventPost attempts to drive QShortcuts from inside `--test` mode failed because QShortcut activation requires the spontaneous-event flag + window-system focus that headless test mode cannot grant).

The debug terminal opens a Lua REPL over a Unix socket. An external test runner or interactive client connects, sends Lua chunks, gets results back. JVE keeps running across many test cases — bring-up amortizes once. Integration tests become sub-second per case. Live debugging of a long-running session becomes a `nc` connection away. This is the foundation that an external real-input runner (Phase 1; AppleScript / `cliclick` / UI-TARS / similar) will sit on top of: external script foregrounds JVE, sends real OS-level key events via its own input layer, then queries JVE's state via the control socket to verify the outcome.

---

## Constitution Check

- **I. Lua-First**: ✅ — protocol is Lua; eval runs in JVE's main Lua state; no DSL invented.
- **II. Library-First**: ✅ — `DebugTerminal` is a focused C++ class (QLocalServer + per-line eval); no framework.
- **III. Test-First**: ⚠️ — initial primitive shipped with a smoke test via shell `nc`; comprehensive coverage in Phase 1 once external-input runner lands.
- **IV. Performance-Conscious**: ✅ — single client, synchronous eval on main thread, no event-loop pumping cost.
- **V. Domain-Driven Naming**: ✅ — "debug terminal" is what it is.
- **VI. Assert-Driven Invariants**: ✅ — bind failures log + return false (CLI-gated; non-fatal); eval errors return as `ERROR:` lines, no silent paths.
- **VII. No Fallbacks or Default Values**: ✅ — no `or default` patterns; missing error message is reported as `<no message>`, not invented.
- **VIII. No Backward Compatibility**: ✅ — new feature, no compat surface.

---

## Functional Requirements

### Phase 0 — landed in this session

- **FR-001** JVE accepts `--control-socket <path>` and `--control-socket=<path>` CLI flags. When given, JVE opens a `QLocalServer` listening on that path before the main Lua script runs.
- **FR-002** When the flag is absent, no server is opened and no socket path is created. Production builds invoked without the flag have zero new attack surface.
- **FR-003** The server accepts **one client at a time**. A second concurrent connection receives `ERROR: debug terminal already has a client\n` and is closed. Subsequent connections after disconnect succeed normally.
- **FR-004** Wire protocol is newline-delimited. Each line of input is a Lua chunk. The chunk is first compiled with `return ` prepended (so bare expressions work); on parse failure that variant is discarded and the chunk is compiled as-is (so statements work).
- **FR-005** Successful evaluation: each return value is formatted on one line, separated by `, `. Result encoding:
  - `nil` → `nil`
  - boolean → `true` / `false`
  - number → `%.14g`
  - string → quoted, control chars + non-ASCII escaped, capped at 256 chars (truncated with `...`)
  - table → `{k=v, ...}` recursively to depth 3 (deeper → `{...}`); 32 entries max (more → `...`)
  - function / userdata / thread / lightuserdata → `<function>` / `<userdata>` / `<thread>` / `<lightuserdata>`
- **FR-006** Eval errors send `ERROR: <lua message>\n`. The Lua stack is restored (top reset).
- **FR-007** After every response (success, error, or empty statement) the server writes a `jve> ` prompt so interactive clients see one.
- **FR-008** On disconnect the server cleans up its client tracking and accepts new connections. On JVE shutdown the socket file is removed from disk so the next launch can bind the same path.
- **FR-009** Stale socket file from a prior crashed run is removed at `start()` time before bind. (`QLocalServer::listen` refuses to bind an existing path.)
- **FR-010** Bind failure is non-fatal: an error is logged and JVE continues to run without the terminal. The terminal is a developer convenience, not a JVE invariant.

### Phase 1 — out of this spec; lifted to follow-up scope

- **FR-101 (separate effort)** External test runner that foregrounds JVE via `osascript -e 'tell app "jve" to activate'`, delivers real OS-level key events (CGEventPost / cliclick / AppleScript / UI-TARS-style tool), then queries JVE state via the debug-terminal socket. Solves the QShortcut activation gap that drove this spec.
- **FR-102 (separate effort)** Test harness library (Python or shell) wrapping `socket → newline-framed → repr-parse` so binding tests look like ordinary scripts.
- **FR-103 (separate effort)** A bundled `tools/jve-repl` interactive client (initial impl: `nc -U /path`; later: a real readline-enabled REPL with history).

---

## Out of Scope (explicit)

- **Multi-client concurrency.** Single client is plenty for tests and interactive use. Add later if proven needed.
- **Authentication.** Filesystem permissions on the socket file are the security model. The socket lives under the user's control (e.g. `/tmp/jve.sock` is mode 0755; tighten to 0700 if needed later). Localhost trust.
- **Sandboxing eval.** `eval` runs in JVE's main Lua state with full `_G` access. That's the point. Anyone with the flag passed knows this.
- **JSON / structured wire format.** Lua strings + the `repr` formatter ARE the structured format. JSON-over-socket would add a parsing layer for no diagnostic gain (the client is going to print the response either way).
- **Cross-platform support.** `QLocalSocket` works on macOS, Linux, and Windows (named pipes), but the use case is dev/test on macOS first. No CI parity required yet.
- **Async / streaming responses.** Each request gets one response line. No subscriptions, no long-running ops. If we need that, add a `subscribe` verb in a follow-up.

---

## Files Touched

```
src/debug_terminal.h                                [NEW] class declaration
src/debug_terminal.cpp                              [NEW] QLocalServer + per-line eval + repr
src/main.cpp                                        [MODIFIED] --control-socket flag, terminal startup before layout.lua
CMakeLists.txt                                      [MODIFIED] Qt6::Network component + JVECore link
src/lua/qt_bindings/input_bindings.cpp              [STAGED] CGEventPost binding (kept for Phase 1 — see FR-101)
```

The `input_bindings.cpp` binding stays in the tree but is not directly used by the debug terminal. It's the in-process input primitive that proved insufficient for QShortcut activation (because QShortcut requires window-system focus that --test mode lacks); Phase 1's external runner will use OS-level injection from a foregrounded helper instead, then read state through this terminal.

---

## Acceptance Criteria

- [x] Building without the flag: zero new behavior; socket file never created.
- [x] Launch with `--control-socket /tmp/jve.sock` → socket file appears; `nc -U /tmp/jve.sock` accepts input.
- [x] `return 1 + 1\n` returns `2\njve> `.
- [x] `x = 5; return x * 2\n` returns `10\njve> ` (statement + return chained).
- [x] `return _VERSION\n` returns `"Lua 5.1"\njve> ` (LuaJIT signature).
- [x] Bad chunk (`return @@\n`) returns `ERROR: <parse err>\njve> ` without killing the server.
- [x] Eval that throws (`error("nope")\n`) returns `ERROR: nope\njve> ` without killing the server.
- [x] Two concurrent connection attempts: second receives "already has a client" and closes; first is unaffected.
- [x] Disconnect + reconnect within one JVE lifetime works.
- [x] JVE shutdown removes the socket file.
- [ ] **Pending** — JVE can be queried from a separate process while still running interactively (drives Phase 1).

---

## Open questions

- Where should the canonical socket path live for the default test run? `/tmp/jve_<pid>.sock`? Per-user `~/.jve/control.sock`? Or always require the caller to pass an explicit path? *Recommendation: explicit path always; refuse to invent.*
- Should `--test` mode also open the control socket by default (so `--test` scripts can also connect from a sidecar process)? Currently it does not. *Recommendation: no — `--test` is a one-shot, the socket is for long-running JVE.*
- Should we cap the eval timeout? An infinite-loop chunk would hang the main thread and freeze JVE. *Recommendation: yes, with a default of 5s; tunable via a future `set_eval_timeout` op.* Deferred to Phase 1.
- Multi-line input — do we want `\\` continuation, or trust the client to send pre-joined Lua? *Recommendation: trust the client.*

---

## Memory / cross-spec notes

- Phase 1 is the consumer of this primitive — see [phase1-test-overhaul.md](phase1-test-overhaul.md) for the test taxonomy, long-lived runner architecture, three coverage axes (every registered command / every keymap entry / every menu item), and the Phase A/B/C plan. Smoke tests post-020 run JVE once with `--control-socket`, drive it from an external Python runner via real OS-level input (cliclick / osascript), and verify outcomes through the socket.
- The CGEventPost binding (in `input_bindings.cpp`) was an unsuccessful in-process attempt at the same problem. Kept for Phase 1 / external-runner use, where the runner is foregrounded and posting events to JVE works correctly.
- See [feedback_smoke_tests_real_keypress_only.md](../../.claude/projects/-Users-joe-Local-jve-spec-kit-claude/memory/feedback_smoke_tests_real_keypress_only.md) for the rule that motivated this entire arc.
