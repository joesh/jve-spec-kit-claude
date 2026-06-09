#!/bin/bash
# Atomic mkdir-based lock so two `make` invocations from the same
# checkout serialize instead of fighting on build/CMakeFiles state and
# the shared VM staging tree (via scripts/_run_in_vm.sh).
#
# Why mkdir not flock: macOS doesn't ship util-linux flock. mkdir is
# atomic on every POSIX filesystem; the .d suffix + pid file gives
# stale-holder detection without a Homebrew dep.
#
# Per-repo: the Makefile derives the lock path from a hash of the
# checkout directory. Two sessions in DIFFERENT checkouts use different
# lock files and stay parallel. Two sessions in the SAME checkout
# serialize through this script.
#
# Usage: with_make_lock.sh <lock-path> <cmd...>
#
# Stale-holder: if mkdir fails AND the holder PID is gone, the prior
# holder died mid-make. Reclaim the lockdir and retry.

set -e

LOCK_PATH="$1"; shift
if [ -z "$LOCK_PATH" ] || [ $# -eq 0 ]; then
    echo "usage: $0 <lock-path> <cmd...>" >&2
    exit 2
fi

LOCKDIR="${LOCK_PATH}.d"
PIDFILE="$LOCKDIR/pid"

cleanup() { rm -rf "$LOCKDIR" 2>/dev/null || true; }

waited=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
    HOLDER=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if [ -n "$HOLDER" ] && ! kill -0 "$HOLDER" 2>/dev/null; then
        echo "[make-lock] stale lock (holder pid=$HOLDER gone); reclaiming" >&2
        rm -rf "$LOCKDIR" 2>/dev/null || true
        continue
    fi
    if [ "$waited" -eq 0 ]; then
        echo "[make-lock] waiting for sibling make (holder pid=${HOLDER:-?})..." >&2
    fi
    waited=$((waited + 2))
    sleep 2
done

trap cleanup EXIT INT TERM HUP
echo "$$" > "$PIDFILE"

"$@"
