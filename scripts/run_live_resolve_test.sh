#!/usr/bin/env bash

# Live-Resolve integration test runner — runs one
# tests/synthetic/integration/live_resolve/<test>.lua inside the full
# JVE process (`jve --test`) against the VM's Resolve Studio. These
# tests are STATE-CHANGING on the Resolve they talk to (import fixture
# timelines, apply test grades, stamp markers, delete timelines), so
# they must run on the VM, never against a host Resolve holding real
# work. Sourcing _run_in_vm.sh re-execs this script (args forwarded)
# on the guest when the VM is reachable. Must run BEFORE `set -e`.
#
# Usage: run_live_resolve_test.sh <test_name.lua | test_name>
#   e.g. run_live_resolve_test.sh test_connect_imported
. "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

set -euo pipefail

# Refusal gate: if we're still on the host (VM off / key absent), DO
# NOT fall through to a host Resolve. The tests themselves also
# skip-unless-live, but a host Resolve that IS live would be mutated —
# refuse outright.
if [ "${JVE_IN_VM:-0}" != "1" ]; then
    echo "run_live_resolve_test: VM unreachable — refusing to drive a" >&2
    echo "host Resolve (state-changing: fixture import/grade/delete)." >&2
    echo "Start the UTM guest and retry." >&2
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "usage: run_live_resolve_test.sh <test_name[.lua]>" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="${1%.lua}"
TEST_PATH="$ROOT_DIR/tests/synthetic/integration/live_resolve/$TEST_NAME.lua"
if [ ! -f "$TEST_PATH" ]; then
    echo "run_live_resolve_test: no such test: $TEST_PATH" >&2
    exit 2
fi

JVE_BIN="$ROOT_DIR/build/bin/jve.app/Contents/MacOS/jve"
if [ ! -x "$JVE_BIN" ]; then
    echo "run_live_resolve_test: jve binary missing at $JVE_BIN" >&2
    echo "(sync-to-vm.sh ships the host-built app; run it first)" >&2
    exit 2
fi

# Absolute script path — relative paths resolve bundle-relative inside
# `jve --test` and silently run stale (memory:
# feedback_jve_test_needs_absolute_path).
exec "$JVE_BIN" --test "$TEST_PATH"
