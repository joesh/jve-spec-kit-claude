#!/bin/bash
# Freshness gate: succeed iff `.last-clean-make` is at least as new as
# every input path read from stdin (NUL-separated). Exit 0 = fresh,
# exit 1 = stale (one offender printed to stderr).
#
# Single source of truth for two callers:
#   • hooks/pre-commit  — feeds staged files; the green make-run that
#     touched the marker provably covered every change being committed.
#   • Makefile  `all:`  — feeds the full source scope; if nothing has
#     moved since the last green run, skip lint+build+tests entirely.
#
# Caller picks the file set; this script only compares mtimes.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MARKER="$REPO_ROOT/.last-clean-make"

if [ ! -f "$MARKER" ]; then
    echo "check_clean_make: no marker at ${MARKER#$REPO_ROOT/}" >&2
    exit 1
fi

marker_mtime=$(stat -f %m "$MARKER")
offender=""
offender_mtime=0

while IFS= read -r -d '' path; do
    [ -z "$path" ] && continue
    [ ! -e "$path" ] && continue
    m=$(stat -f %m "$path" 2>/dev/null) || continue
    if [ "$m" -gt "$offender_mtime" ]; then
        offender_mtime=$m
        offender=$path
    fi
done

if [ "$offender_mtime" -gt "$marker_mtime" ]; then
    echo "check_clean_make: ${offender#$REPO_ROOT/} is newer than .last-clean-make" >&2
    exit 1
fi

exit 0
