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

# If a sibling `make` is in flight, wait for it instead of pronouncing
# "stale" against the in-progress run's about-to-be-refreshed marker.
# Two sessions otherwise race: A starts make → B's pre-commit fires
# before A touches the marker → B says stale → B starts a second make
# that fights A on build/ state. The Makefile's lock dispatcher already
# serializes makes via with_make_lock.sh; we just need to honour the
# same lock from gate callers.
#
# Skip when we are ALREADY inside the make (JVE_MAKE_LOCKED set by the
# Makefile re-invocation) — waiting on the lock we hold would deadlock.
if [ "${JVE_MAKE_LOCKED:-0}" != "1" ]; then
    lock_hash=$(printf "%s" "$REPO_ROOT" | shasum | cut -c 1-8)
    lockdir="/tmp/jve-make-${lock_hash}.lock.d"
    pidfile="$lockdir/pid"
    waited=0
    while [ -d "$lockdir" ]; do
        holder=$(cat "$pidfile" 2>/dev/null || echo "")
        if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
            break  # stale lock; with_make_lock.sh will reclaim on next make
        fi
        if [ "$waited" -eq 0 ]; then
            echo "check_clean_make: waiting for sibling make (holder pid=$holder)..." >&2
        fi
        waited=$((waited + 2))
        sleep 2
    done
fi

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
