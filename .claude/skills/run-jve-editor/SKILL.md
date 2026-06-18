---
name: run-jve-editor
description: Build, launch, drive, screenshot, or smoke-test the JVE Editor desktop app (Qt6/LuaJIT video editor). Use when asked to run, start, build, test, screenshot, or programmatically exercise JVE / the editor.
---

# Run JVE Editor

JVE is a macOS desktop NLE (Qt6 C++ + LuaJIT, SQLite `.jvp` projects). The
programmatic handle is **`jve --test <script.lua>`**: it boots the *full* app
process — every C++/Qt/EMP binding plus the Lua model/command/DB stack — with
**no window**, runs your Lua script, and exits `0` on success / `1` on any error
or failed `assert`. That is how an agent drives JVE headlessly.

All paths below are relative to the repo root. The driver lives at
`.claude/skills/run-jve-editor/driver.sh`.

## Prerequisites

The app is built by the project's normal toolchain (CMake + Qt6 + LuaJIT,
already vendored). No extra OS packages were needed on this macOS host. The
`shot` subcommand needs **Accessibility permission** for your terminal
(System Settings → Privacy & Security → Accessibility) to read window bounds
and synthesize the capture region.

## Build

```bash
.claude/skills/run-jve-editor/driver.sh build   # = cd build && make jve -j4 (exe only, skips tests)
```

A prebuilt binary at `build/bin/jve.app/Contents/MacOS/jve` is reused if present.
For the full gate (C++ + luacheck + all test suites) run `make -j4` from the
repo root instead — that is the project's authority, but it is slow.

## Run (agent path) — drive it headlessly

```bash
# Bundled demo: probes a media fixture through the C++ EMP bindings AND opens a
# fresh project through the real OpenProject command path. Prints PASS, exits 0.
.claude/skills/run-jve-editor/driver.sh smoke

# Run any --test script (boots full app, full bindings, then exits):
.claude/skills/run-jve-editor/driver.sh run path/to/your_test.lua
```

Verified output of `smoke` this session:

```
--- demo_smoke.lua ---
  [bindings] test_tone_48k_stereo.wav: sr=48000 ch=2 dur=2.00s has_audio=true has_video=false
  [model] project=f4b18baa seq=0c9ca179 sequence_count=1 media_count=0
PASS demo_smoke.lua
```

Write your own `--test` script by copying the shape of `demo_smoke.lua` (or any
`tests/synthetic/integration/test_*.lua`): `require` the integration env, exercise
real subsystems, `print` results, end with a `PASS` line. If your script lives
**outside** `tests/`, replicate the `package.path` bootstrap at the top of
`demo_smoke.lua` — `jve --test` only auto-adds the `tests/` tree for scripts
that live under it.

`--test` mode is the right handle for anything touching media decode (EMP/TMB),
DRP/DRT import (needs `qt_xml_parse`), the model/command/DB layer, or Qt binding
behavior. Enable logging with `JVE_LOG=media:detail` (areas: `ticks audio video
timeline commands database ui media`; meta `play`, `all`; levels `detail event
warn error`).

## Run (driving the live GUI with real OS input)

For tests that must exercise the actual rendered UI (keystrokes, clicks, menus),
the project ships a Python smoke harness under `tests/live/` that foregrounds a
dedicated `jve --control-socket` instance and drives it via real OS events
(osascript / CGEventPost), reading state back over the socket. See
`tests/live/PRIMITIVES.md` (what you can call) and
`tests/live/SMOKE_TEST_AUTHORING.md`. This needs Accessibility permission and
steals foreground focus. Do **not** mutate model state programmatically in these
smokes — input must be real OS input.

## Run (human path)

```bash
.claude/skills/run-jve-editor/driver.sh gui                      # opens default Untitled project
.claude/skills/run-jve-editor/driver.sh gui "/path/to/project.jvp"
# or, for a Finder/Dock launch:  open build/bin/jve.app
```

Opens the real 3-panel editor window (project browser · source/timeline monitors ·
inspector, with V/A track headers). Useless purely headless — it waits for a
window. Ctrl-C / quit to stop.

## Screenshot

```bash
.claude/skills/run-jve-editor/driver.sh shot   # → .claude/skills/run-jve-editor/screenshot.png
```

Launches a fresh no-arg GUI, captures **only JVE's window** (not the whole
desktop), then quits it. `screenshot.png` in this dir was produced this way and
shows the full rendered NLE.

## Verify it didn't crash on boot

```bash
.claude/skills/run-jve-editor/driver.sh startup   # launches GUI no-arg, confirms no early crash, quits
# prints "Smoke run completed", exits 0
```

## Gotchas

- **`jve --test` resolves a relative script path against the .app bundle's
  `Contents/Resources`, not your CWD** → "test script not found". The driver
  always passes an absolute path; do the same if you invoke `jve --test` directly.
- **`package.path` for `--test` is derived by walking up from the script to a
  `tests/` ancestor.** A script outside `tests/` (like this skill's
  `demo_smoke.lua`) can't `require("synthetic.…")` until it prepends the repo's
  `tests/` tree itself — see the `debug.getinfo` prelude in `demo_smoke.lua`.
- **Launching the GUI with a non-existent `.jvp` path crashes** with
  `layout.lua: Database has no projects` — the CLI-arg path expects an *existing*
  populated project. Use no-arg (opens/creates the default Untitled project) for
  a throwaway window, or pre-create the project first.
- **Joe runs parallel sessions.** Before deleting a project DB's stale `-shm`,
  check `pgrep -x jve` first (a running editor owns it). `driver.sh shot` already
  guards this. Never touch a `.jvp` you didn't create.
- **`shot`/live-smoke need Accessibility** granted to the invoking terminal, or
  `osascript` returns nothing and the capture region can't be computed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `binary not built at …` | `.claude/skills/run-jve-editor/driver.sh build` |
| `test script not found` | pass an **absolute** path to `jve --test` (the driver does this) |
| `module 'synthetic.…' not found` | script is outside `tests/`; add the `package.path` prelude from `demo_smoke.lua` |
| `Database has no projects` on GUI launch | don't pass a non-existent `.jvp`; launch no-arg or pre-create the project |
| `shot` says "no window bounds" | grant Accessibility to your terminal |
