#!/usr/bin/env bash
# driver.sh — build, launch, and drive JVE Editor (Qt6/LuaJIT desktop NLE).
#
# JVE is a macOS desktop app. The programmatic handle is `jve --test
# <script.lua>`, which boots the FULL app process (all C++/Qt/EMP bindings +
# the Lua model/command/DB stack) WITHOUT opening a window, runs your Lua
# script, and exits 0 on success / 1 on any error or failed assert. That is
# the path for anything an agent needs to drive headlessly.
#
# Subcommands (paths are relative to the repo root):
#   ./driver.sh build            # build just the executable (skips tests)
#   ./driver.sh smoke            # run the bundled demo_smoke.lua via --test
#   ./driver.sh run <script.lua> # run an arbitrary --test Lua script
#   ./driver.sh startup          # headless GUI boot/crash check, then quit
#   ./driver.sh gui [project.jvp]# launch the real GUI (human path; steals focus)
#   ./driver.sh shot [out.png]   # launch a fresh GUI, screenshot its window, quit
#
# Every command here was run and verified on macOS this session.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"   # <repo>/.claude/skills/run-jve-editor → <repo>
APP="$ROOT/build/bin/jve.app/Contents/MacOS/jve"

die() { echo "ERROR: $*" >&2; exit 1; }
need_app() { [[ -x "$APP" ]] || die "binary not built at $APP — run: ./driver.sh build"; }

# Per-invocation template dir: project_templates regenerates a shared .jvp on
# every fresh open; isolating it avoids races / stale-state across runs.
TPL="/tmp/jve/templates_driver_$$"

cmd_build() {
  echo ">> building jve (exe only, no tests)…"
  ( cd "$ROOT/build" && make jve -j4 )
  echo ">> built: $APP"
}

# Run a --test script with full bindings; stream output, propagate exit code.
cmd_run() {
  need_app
  local script="${1:?usage: ./driver.sh run <script.lua>}"
  [[ -f "$script" ]] || die "script not found: $script"
  local abs; abs="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"
  mkdir -p /tmp/jve
  echo ">> jve --test $abs"
  JVE_TEMPLATE_DIR="$TPL" "$APP" --test "$abs"
}

cmd_smoke() { cmd_run "$SKILL_DIR/demo_smoke.lua"; }

# Launch the GUI with no project, confirm it doesn't crash on startup, quit.
cmd_startup() {
  need_app
  JVE_SMOKE_WAIT_SECONDS="${JVE_SMOKE_WAIT_SECONDS:-3}" bash "$ROOT/tests/test_smoke_run_app.sh"
}

# Human path: open the real editor window. No project arg opens the default
# Untitled project. Steals foreground focus; useless purely headless.
cmd_gui() {
  need_app
  mkdir -p /tmp/jve
  if [[ $# -ge 1 ]]; then
    JVE_TEMPLATE_DIR="$TPL" exec "$APP" "$1"
  else
    JVE_TEMPLATE_DIR="$TPL" exec "$APP"
  fi
}

# Launch a fresh no-arg GUI, screenshot ONLY its window (not the whole desktop),
# then quit. Needs Accessibility permission for the terminal (System Events).
cmd_shot() {
  need_app
  local out="${1:-$SKILL_DIR/screenshot.png}"
  mkdir -p /tmp/jve
  pgrep -x jve >/dev/null || rm -f "$HOME/Documents/JVE Projects/Untitled Project.jvp-shm"
  JVE_TEMPLATE_DIR="$TPL" "$APP" >/tmp/jve_shot.log 2>&1 &
  local pid=$!
  echo ">> launched pid=$pid; waiting for window…"
  local b=""
  for _ in $(seq 1 24); do
    kill -0 "$pid" 2>/dev/null || { tail -6 /tmp/jve_shot.log; die "app died during startup"; }
    b="$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$pid"') to get {position, size} of front window' 2>/dev/null || true)"
    [[ -n "$b" ]] && break
    sleep 0.5
  done
  [[ -n "$b" ]] || { kill -KILL "$pid" 2>/dev/null || true; die "no window bounds (Accessibility not granted to this terminal?)"; }
  local x y w h
  x="$(echo "$b" | cut -d, -f1 | tr -d ' ')"; y="$(echo "$b" | cut -d, -f2 | tr -d ' ')"
  w="$(echo "$b" | cut -d, -f3 | tr -d ' ')"; h="$(echo "$b" | cut -d, -f4 | tr -d ' ')"
  screencapture -x -R"$x,$y,$w,$h" "$out"
  echo ">> captured ${w}x${h} → $out"
  kill -TERM "$pid" 2>/dev/null || true; sleep 0.6; kill -KILL "$pid" 2>/dev/null || true
}

case "${1:-smoke}" in
  build)   cmd_build ;;
  smoke)   cmd_smoke ;;
  run)     shift; cmd_run "$@" ;;
  startup) cmd_startup ;;
  gui)     shift; cmd_gui "$@" ;;
  shot)    shift; cmd_shot "$@" ;;
  *)       die "unknown command '$1' (build|smoke|run|startup|gui|shot)" ;;
esac
