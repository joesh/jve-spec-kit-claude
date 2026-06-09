#!/bin/bash
# Integration test: launch the editor and verify it reaches quiescent state.
# Tests TWO paths:
#   1. CLI arg with fresh project → full layout init
#   2. No CLI arg → welcome screen (last_project_path cleared)
#
# This is the only test that exercises the REAL startup path — not --test mode.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EDITOR="$REPO_ROOT/build/bin/jve"
TEST_DB="/tmp/jve/test_editor_startup.jvp"

echo "=== Editor Startup Smoke Test ==="

# Step 1: Create fresh project DB via --test mode
echo "  Creating test project..."
mkdir -p /tmp/jve
TEST_DB_PATH="$TEST_DB" "$EDITOR" --test "$SCRIPT_DIR/helper_editor_startup.lua" > /dev/null 2>&1

# Step 2a: Launch with CLI arg (full layout path)
echo "  Test A: CLI arg → full layout..."
JVE_QUIT_AFTER_INIT=1 JVE_QUIT_DELAY_MS=2000 "$EDITOR" "$TEST_DB" > /tmp/jve/test_startup_a.txt 2>&1
EXIT_A=$?
if [ $EXIT_A -ne 0 ]; then
    echo "  FAILED (exit $EXIT_A):"
    cat /tmp/jve/test_startup_a.txt
    exit 1
fi
echo "  Test A passed"

# Step 2b: Launch with no arg, no last_project_path (welcome screen path)
echo "  Test B: No project → welcome screen..."
SAVED_LAST=""
if [ -f ~/.jve/last_project_path ]; then
    SAVED_LAST=$(cat ~/.jve/last_project_path)
    rm -f ~/.jve/last_project_path
fi

JVE_QUIT_AFTER_INIT=1 JVE_QUIT_DELAY_MS=2000 "$EDITOR" > /tmp/jve/test_startup_b.txt 2>&1
EXIT_B=$?

# Restore last_project_path
if [ -n "$SAVED_LAST" ]; then
    echo -n "$SAVED_LAST" > ~/.jve/last_project_path
fi

if [ $EXIT_B -ne 0 ]; then
    echo "  FAILED (exit $EXIT_B):"
    cat /tmp/jve/test_startup_b.txt
    exit 1
fi
echo "  Test B passed"

# Cleanup
rm -f "$TEST_DB" "${TEST_DB}-wal" "${TEST_DB}-shm"

echo "✅ test_editor_startup.sh passed"
