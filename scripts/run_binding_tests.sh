#!/usr/bin/env bash

# If the UTM guest is reachable, sync the host tree and re-exec this script
# there. Falls through to host-local execution when the VM is off / key absent.
# Must run BEFORE `set -e`.
. "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

set -euo pipefail

# Binding test runner — dispatches batch_binding.lua into a single long-lived
# JVEEditor process via --test. Matches the integration runner's batch model
# (tests/integration/batch_runner.lua + batch_*.lua): one process, sequential
# tests via pcall(dofile), no parallel spawn storm. Test discovery, SLOW_TEST
# skip, and per-test pass/fail reporting live in batch_binding.lua. This
# script's job is to launch the binary and translate its exit code.
#
# Usage: ./scripts/run_binding_tests.sh
#   RUN_SLOW_TESTS=1 to include tests marked SLOW_TEST

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Prefer JVE_BINARY (set by cmake via $<TARGET_FILE:jve>); fall back to
# BUILD_DIR-derived path for standalone script invocations.
BUILD_DIR="${BUILD_DIR:-build}"
BINARY="${JVE_BINARY:-$ROOT_DIR/$BUILD_DIR/bin/jve.app/Contents/MacOS/jve}"
BATCH="$ROOT_DIR/tests/binding/batch_binding.lua"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: jve binary not found at $BINARY" >&2
  echo "       Run 'make -j4' first." >&2
  exit 2
fi
if [[ ! -f "$BATCH" ]]; then
  echo "ERROR: binding batch driver not found at $BATCH" >&2
  exit 2
fi

# Forward RUN_SLOW_TESTS through to the in-process batch driver, which is
# the authoritative skip filter.
RUN_SLOW_TESTS="${RUN_SLOW_TESTS:-0}" exec "$BINARY" --test "$BATCH"
