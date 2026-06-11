#!/usr/bin/env bash

# Resolve-helper Python unit tests (tools/resolve-helper/test_*.py).
# Offline-pure: every test drives the verbs/parsers with fakes — no
# Resolve, no VM, no JVE binary — so this runs on the host in <1s and
# needs no _run_in_vm.sh dispatch.
#
# Wired into `make -j4` via the CMake helper_tests target (phase A,
# parallel with lua_tests/binding_tests). Discovery, not an explicit
# module list: a new test_*.py file must never silently not-run —
# that gap is how LocaleRateWireCodeTests sat failing at HEAD unnoticed
# (2026-06-11).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/tools/resolve-helper"
exec python3 -m unittest discover -s . -p 'test_*.py'
